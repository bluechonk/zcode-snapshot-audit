#Requires -Version 7.0
<#
.SYNOPSIS
  ZCode 仓库快照上传行为 - 只读取证审计脚本。

.DESCRIPTION
  固化 2026-09-19 对 ZCode 3.12.3 (Windows x64) 的完整排查逻辑，共 8 步：

    步骤1  定位安装与版本（文章指控针对 3.12.3，先对版本）
    步骤2  checkpoints 目录清点 + state.json 判读（行为指纹）
    步骤3  manifest 分析：判定快照是否收录 .git 内部文件，并对照磁盘真实 .git
    步骤4  extra-manifest / 加密信封判读（确认"只有服务端能解密"）
    步骤5  设置开关（repoSnapshotIndexingEnabled + UserConfigured 双门控）
    步骤6  日志关键词扫描（上传链路通常不留 INFO 级痕迹，预期为空）
    步骤7  app.asar 静态取证（字节扫描关键符号，确认代码层上传链路与 .git 强制收录）
    步骤8  本机时间线重建 + 结论评分

  原则：全程只读，不修改 ZCode 任何文件，不发起任何网络请求。
  报告写入 reports/，包含本机路径与少量工作区文件名样例，外发前请自行脱敏。

.EXAMPLE
  pwsh -NoProfile -File scripts/Invoke-ZCodeSnapshotAudit.ps1

.EXAMPLE
  pwsh -NoProfile -File scripts/Invoke-ZCodeSnapshotAudit.ps1 -SkipAsarScan   # 快速模式
#>
[CmdletBinding()]
param(
  [string]$ZCodeDir     = (Join-Path $env:LOCALAPPDATA 'Programs\ZCode'),
  [string]$ZcodeDataDir = (Join-Path $env:USERPROFILE '.zcode'),
  [string]$ReportDir,
  [switch]$SkipAsarScan,
  [switch]$KeepRawContext,
  [switch]$NoRedact
)

if (-not $ReportDir) { $ReportDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'reports' }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

# ---------------- 通用工具 ----------------

function Get-P {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($null -ne $p) { $p.Value } else { $null }
}

function Convert-EpochMs {
  param($Ms)
  if ($null -eq $Ms -or $Ms -eq 0) { return $null }
  try { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Ms).LocalDateTime } catch { $null }
}

function Format-MiB { param($Bytes) if ($null -eq $Bytes) { return '-' }; '{0:N2} MiB' -f ($Bytes / 1MB) }

function Get-HomePrefixRedacted { param([string]$Text)
  if ($NoRedact -or [string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($env:USERPROFILE)) { return $Text }
  return $Text.Replace($env:USERPROFILE, '~').Replace("$env:USERPROFILE\", '~\')
}

$script:Findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
  param([ValidateSet('CRITICAL', 'WARN', 'INFO', 'PASS')][string]$Level, [string]$Claim, [string]$Evidence)
  $script:Findings.Add([pscustomobject]@{ level = $Level; claim = $Claim; evidence = $Evidence }) | Out-Null
}

$script:Sections = New-Object System.Collections.Generic.List[object]
function Add-Section {
  param([string]$Title, $Items, [string]$Note = '')
  $script:Sections.Add([pscustomobject]@{ title = $Title; items = @($Items | ForEach-Object { $_ }); note = $Note }) | Out-Null
}

function ConvertTo-MdTable {
  param($Items)
  $arr = @()
  foreach ($it in @($Items | ForEach-Object { $_ })) { if ($null -ne $it) { $arr += $it } }
  if ($arr.Count -eq 0) { return '_(无数据)_' }
  $props = @($arr[0].PSObject.Properties.Name)
  $toCell = {
    param($v)
    if ($null -eq $v) { return '' }
    if ($v -is [string]) { $t = $v }
    elseif ($v.GetType().IsValueType) { $t = $v.ToString() }
    else { $t = ($v | ConvertTo-Json -Compress -Depth 4) }
    return ((($t -replace '\|', '\|') -replace "(`r|`n)+", ' '))
  }
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add(('| ' + ($props -join ' | ') + ' |'))
  $lines.Add(('| ' + (($props | ForEach-Object { '---' }) -join ' | ') + ' |'))
  foreach ($row in $arr) {
    $cells = foreach ($p in $props) { & $toCell $row.$p }
    $lines.Add(('| ' + ($cells -join ' | ') + ' |'))
  }
  return ($lines -join "`n")
}

# ---------------- 步骤1 定位安装与版本 ----------------

$exePath  = Join-Path $ZCodeDir 'ZCode.exe'
$asarPath = Join-Path $ZCodeDir 'resources\app.asar'

$ver = $null
if (Test-Path $exePath) { $ver = (Get-Item $exePath).VersionInfo }
$installManifest = Join-Path $ZCodeDir '.zcode-install-manifest'

$installInfo = [pscustomobject]@{
  '安装目录'           = (Get-HomePrefixRedacted $ZCodeDir)
  'ProductVersion'     = Get-P $ver 'ProductVersion'
  'FileVersion'        = Get-P $ver 'FileVersion'
  'app.asar 存在'      = (Test-Path $asarPath)
  'app.asar 大小'      = if (Test-Path $asarPath) { Format-MiB (Get-Item $asarPath).Length } else { '-' }
  'exe 创建时间'       = if (Test-Path $exePath) { (Get-Item $exePath).CreationTime } else { $null }
  'exe 修改时间'       = if (Test-Path $exePath) { (Get-Item $exePath).LastWriteTime } else { $null }
  '安装清单创建时间'   = if (Test-Path $installManifest) { (Get-Item $installManifest).CreationTime } else { $null }
}
Add-Section '步骤1 安装与版本' $installInfo
Write-Host "`n[步骤1] ZCode ProductVersion = $(Get-P $ver 'ProductVersion')  FileVersion = $(Get-P $ver 'FileVersion')" -ForegroundColor White

# ---------------- 步骤2 checkpoints 清点 + state.json 判读 ----------------

$checkpointsDir = Join-Path $ZcodeDataDir 'v2\checkpoints'
$workspaceSummaries = @()

if (Test-Path $checkpointsDir) {
  foreach ($wsDir in (Get-ChildItem $checkpointsDir -Directory -Force)) {
    $statePath = Join-Path $wsDir.FullName 'state.json'
    $state = $null
    if (Test-Path $statePath) {
      try { $state = Get-Content $statePath -Raw | ConvertFrom-Json } catch { $state = $null }
    }
    $active  = Get-P $state 'activeUpload'
    $pending = Get-P $state 'pendingUpload'
    $lcs     = Get-P $state 'lastCompressedSize'
    $attr    = Get-P $active 'attribution'

    $artifactPath = Get-P $active 'encryptedArtifactPath'
    if (-not $artifactPath) { $artifactPath = Get-P $pending 'encryptedArtifactPath' }
    $artifactInfo = if ($artifactPath -and (Test-Path $artifactPath)) { Get-Item $artifactPath } else { $null }
    $cred = Get-P $active 'uploadCredentialHandle'
    $credDisp = if ($cred) { "$($cred.Substring(0,8))..." } else { $null }

    $inv = @{ manifests = 0; extra = 0; pending = 0; tmp = 0; totalBytes = 0 }
    foreach ($f in (Get-ChildItem $wsDir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)) {
      $inv.totalBytes += $f.Length
      switch -Regex ($f.DirectoryName) {
        '\\manifests$'      { $inv.manifests++ }
        '\\extra-manifests$'{ $inv.extra++ }
        '\\pending$'        { $inv.pending++ }
        '\\tmp$'            { $inv.tmp++ }
      }
    }

    $workspaceSummaries += [pscustomobject]@{
      '目录(工作区哈希)'            = $wsDir.Name
      'workspacePath'               = (Get-HomePrefixRedacted (Get-P $state 'workspacePath'))
      'state.json 创建时间'         = if (Test-Path $statePath) { (Get-Item $statePath).CreationTime } else { $null }
      '服务端已接受(lastAccepted)'  = if (Get-P $state 'lastAcceptedManifestHash') { "是 ($((Get-P $state 'lastAcceptedManifestHash').Substring(0,12))...)" } else { '否' }
      '待传任务存在'                = if ($active -or $pending) { '是' } else { '否' }
      'kind'                        = (Get-P $active 'kind')
      'attemptCount'                = (Get-P $active 'attemptCount')
      'failureCount'                = (Get-P $attr 'failureCount')
      'captureStage'                = (Get-P $attr 'captureStage')
      '凭证句柄(服务端签发)'        = $credDisp
      '任务创建时间'                = (Convert-EpochMs (Get-P $active 'createdAt'))
      '最近尝试时间'                = (Convert-EpochMs (Get-P $active 'lastAttemptAt'))
      '加密制品'                    = if ($artifactInfo) { Format-MiB $artifactInfo.Length } else { '-' }
      '制品写入时间'                = if ($artifactInfo) { $artifactInfo.LastWriteTime } else { $null }
      '源工作区大小'                = Format-MiB (Get-P $lcs 'workspaceSizeBytes')
      '上次加密大小'                = Format-MiB (Get-P $lcs 'encryptedSizeBytes')
      'manifest/extra/pending/tmp'  = '{0}/{1}/{2}/{3}' -f $inv.manifests, $inv.extra, $inv.pending, $inv.tmp
      '目录总大小'                  = Format-MiB $inv.totalBytes
    }
  }
}
Add-Section '步骤2 checkpoints 工作区状态摘要' $workspaceSummaries 'lastAcceptedManifestHash 仅在"上传被服务端接受"后写入；存在即证明至少一次成功上传。uploadCredentialHandle 为服务端签发，其存在即证明客户端真实调用过 /api/v1/snapshot/upload-credential。'
Write-Host "[步骤2] 快照工作区数量: $($workspaceSummaries.Count)" -ForegroundColor White

# ---------------- 步骤3 manifest 的 .git 收录分析 ----------------

$gitSegmentRe      = '(^|/|\\)\.git(/|\\|$)'                                  # 只命中真实 .git 目录段
$gitCosmeticRe     = '(^|/|\\)\.git(ignore|keep|modules|attributes|github)(/|$)' # .gitignore/.github 等普通文件
$manifestAnalyses  = @()

foreach ($ws in $workspaceSummaries) {
  $wsDirName = $ws.'目录(工作区哈希)'
  $wsDir = Join-Path $checkpointsDir $wsDirName
  $statePath = Join-Path $wsDir 'state.json'
  if (-not (Test-Path $statePath)) { continue }
  try { $state = Get-Content $statePath -Raw | ConvertFrom-Json } catch { continue }

  $candidates = @()
  $acceptedPath = Get-P $state 'lastAcceptedManifestPath'
  if ($acceptedPath -and (Test-Path $acceptedPath)) { $candidates += $acceptedPath }
  $candidates += (Get-ChildItem (Join-Path $wsDir 'manifests') -Filter '*.json' -File -ErrorAction SilentlyContinue).FullName
  $candidates = $candidates | Select-Object -Unique -First 3

  foreach ($mp in $candidates) {
    try { $m = Get-Content $mp -Raw | ConvertFrom-Json } catch { continue }
    $files = @(Get-P $m 'files')
    $gitInternal = @($files | Where-Object { $_.path -match $gitSegmentRe })
    $gitCosmetic = @($files | Where-Object { $_.path -match $gitCosmeticRe })

    $wsPath = Get-P $state 'workspacePath'
    $diskGit = @()
    if ($wsPath -and (Test-Path $wsPath)) {
      $diskGit = @(Get-ChildItem -LiteralPath $wsPath -Recurse -Force -Depth 4 -Filter '.git' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' })
    }

    $manifestAnalyses += [pscustomobject]@{
      'manifest'              = Split-Path $mp -Leaf
      'schema'                = (Get-P $m 'schema')
      'workspaceKey'          = (Get-HomePrefixRedacted (Get-P $m 'workspaceKey'))
      'createdAt'             = (Convert-EpochMs (Get-P $m 'createdAt'))
      '收录文件数'            = $files.Count
      '收录字节数'            = Format-MiB (Get-P (Get-P $m 'stats') 'includedBytes')
      '.git 内部文件收录数'   = $gitInternal.Count
      '.gitignore 等普通文件' = $gitCosmetic.Count
      '磁盘真实 .git 目录数'  = $diskGit.Count
      '.git 样例(前10)'       = if ($gitInternal.Count -gt 0) { ($gitInternal | Select-Object -First 10 | ForEach-Object { $_.path }) -join '; ' } else { '(无)' }
    }
  }
}
Add-Section '步骤3 manifest 的 .git 收录分析' $manifestAnalyses '判读：.git 内部收录数 > 0 → git 历史被打包。若磁盘存在 .git 但收录为 0，通常是工作区根不是 git 仓库（git ls-files 失败 → 降级目录遍历跳过一切名为 .git 的目录）；一旦工作区根是 git 仓库，代码会强制收录完整 .git。'
Write-Host "[步骤3] 已分析 manifest: $($manifestAnalyses.Count) 份" -ForegroundColor White

# ---------------- 步骤4 extra-manifest 与加密信封 ----------------

$sec4 = @()
foreach ($ws in $workspaceSummaries) {
  $wsDir = Join-Path $checkpointsDir $ws.'目录(工作区哈希)'
  foreach ($em in (Get-ChildItem (Join-Path $wsDir 'extra-manifests') -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 2)) {
    try { $e = Get-Content $em.FullName -Raw | ConvertFrom-Json } catch { continue }
    $sec4 += [pscustomobject]@{
      '类型' = 'extra-manifest(全局配置快照)'
      'schema' = (Get-P $e 'schema')
      'groups' = (@(Get-P $e 'groups') | ForEach-Object { "{0}({1} 文件)" -f (Get-P $_ 'groupId'), (@(Get-P $_ 'files')).Count }) -join ', '
      '来源' = (@(Get-P $e 'groups') | ForEach-Object { @(Get-P $_ 'files') | ForEach-Object { Get-P $_ 'source' } } | Select-Object -Unique) -join ', '
    }
  }
  $envPath = Get-P (Get-P (Get-Content (Join-Path $wsDir 'state.json' ) -Raw | ConvertFrom-Json) 'activeUpload') 'encryptionEnvelopePath'
  if (-not $envPath) { $envPath = (Get-ChildItem (Join-Path $wsDir 'pending') -Filter '*.envelope.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
  if ($envPath -and (Test-Path $envPath)) {
    try { $env2 = Get-Content $envPath -Raw | ConvertFrom-Json } catch { $env2 = $null }
    $sec4 += [pscustomobject]@{
      '类型' = '加密信封'
      'schema' = (Get-P $env2 'schema')
      'groups' = "content=$(Get-P $env2 'contentAlgorithm')  keyWrap=$(Get-P $env2 'keyWrapAlgorithm')  keyId=$(Get-P $env2 'keyId')"
      '来源' = if (Get-P $env2 'encryptedDataKey') { 'encryptedDataKey 存在(值不展示)——数据密钥以服务端公钥包裹, 仅 ZCode 服务端可解密' } else { '无 encryptedDataKey' }
    }
  }
}
Add-Section '步骤4 全局配置快照与加密信封' $sec4 '信封加密 ≠ 端到端加密：数据密钥用 RSA-OAEP 包给服务端公钥，本地自身无法解密。'

# ---------------- 步骤5 设置开关 ----------------

$settingPath = Join-Path $ZcodeDataDir 'v2\setting.json'
$settingInfo = @()
if (Test-Path $settingPath) {
  try {
    $st = Get-Content $settingPath -Raw | ConvertFrom-Json
    $settingInfo += [pscustomobject]@{
      '文件' = (Get-HomePrefixRedacted $settingPath)
      'repoSnapshotIndexingEnabled'          = (Get-P $st 'repoSnapshotIndexingEnabled')
      'repoSnapshotIndexingUserConfigured'   = (Get-P $st 'repoSnapshotIndexingUserConfigured')
      'instantGrepIndexingEnabled'           = (Get-P $st 'instantGrepIndexingEnabled')
      '说明' = '代码事实: host 侧门控要求 Enabled===true 且 UserConfigured===true 才捕获; schema 默认值为 false, 出现 true 说明被显式打开过'
    }
  } catch { $settingInfo += [pscustomobject]@{ '文件' = $settingPath; '错误' = 'setting.json 解析失败' } }
}
Add-Section '步骤5 设置开关' $settingInfo
$vEnabled = if ($settingInfo.Count -gt 0) { Get-P $settingInfo[0] 'repoSnapshotIndexingEnabled' } else { $null }
$vConfigured = if ($settingInfo.Count -gt 0) { Get-P $settingInfo[0] 'repoSnapshotIndexingUserConfigured' } else { $null }
Write-Host "[步骤5] repoSnapshotIndexingEnabled=$vEnabled  UserConfigured=$vConfigured" -ForegroundColor White

# ---------------- 步骤6 日志关键词扫描 ----------------

$logPatterns = @('snapshot-upload', 'upload-credential', 'uploadCredential', 'aliyuncs', 'x_oss', 'repo-snapshot', 'repo_snapshot')
$logHits = @()
$logDirs = @((Join-Path $ZcodeDataDir 'v2\logs'), (Join-Path $ZcodeDataDir 'cli\log'))
foreach ($ld in $logDirs) {
  if (-not (Test-Path $ld)) { continue }
  $logs = Get-ChildItem $ld -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5
  foreach ($pattern in $logPatterns) {
    $hits = @($logs | ForEach-Object { Select-String -Path $_.FullName -Pattern $pattern -SimpleMatch -ErrorAction SilentlyContinue })
    if ($hits.Count -gt 0) {
      $logHits += [pscustomobject]@{
        '关键词' = $pattern
        '命中数' = $hits.Count
        '样例'   = (($hits | Select-Object -First 2 | ForEach-Object { $_.Line.Substring(0, [Math]::Min(200, $_.Line.Length)) }) -join ' // ')
      }
    }
  }
}
Add-Section '步骤6 日志关键词扫描' $logHits '预期通常为空：上传客户端使用 debug 级日志，INFO 级日志不留网络痕迹。日志为空不能证明没有上传，需结合 state.json 判读。'
Write-Host "[步骤6] 日志命中: $($logHits.Count) 组" -ForegroundColor White

# ---------------- 步骤7 app.asar 静态取证 ----------------

$asarResult = $null
if (-not $SkipAsarScan) {
  if (Test-Path $asarPath) {
    Write-Host '[步骤7] 正在字节扫描 app.asar (约 300MB, 需数十秒)...' -ForegroundColor White
    $enc = [System.Text.Encoding]::GetEncoding('latin1')
    $s = $enc.GetString([System.IO.File]::ReadAllBytes($asarPath))

    $needleTable = [ordered]@{
      'upload-credential'                = '上传凭证接口(服务端签发 OSS 凭证)'
      'RepoSnapshotUploadClient'         = '快照上传客户端类'
      'repo-snapshot.tar.gz.enc'         = 'OSS 上传制品文件名'
      'uploadPutObject'                  = 'OSS PUT 直传'
      'uploadPostObject'                 = 'OSS POST 表单直传'
      'x_oss_security_token'             = 'OSS 临时凭证字段'
      'appendRootGitMetadataPaths'       = '把工作区根 .git 全部内容追加进快照(强制收录源头)'
      'walkGitMetadataFiles'             = '递归遍历 .git 目录且无内容过滤'
      'shouldIncludeRepoSnapshotPath'    = '快照收录最终过滤器'
      'listGitVisibleFiles'              = 'git ls-files --cached --others --exclude-standard 收集'
      'looksLikeSecretPath'              = 'secret 类路径排除(.env*/id_rsa/*.pem/*.key/token/secret)'
      'migrateLegacyRepoSnapshotRootDir' = 'repo-snapshots→checkpoints 目录迁移(机制早于当前版本)'
      'markAcceptedManifest'             = '上传被服务端接受后的状态写入点'
      'repoSnapshotIndexingEnabled===!'  = '设置开关的运行时门控'
    }
    $ctxLen = if ($KeepRawContext) { 1000 } else { 260 }
    $needleRows = @()
    foreach ($needle in $needleTable.Keys) {
      $count = 0; $firstCtx = ''
      $i = $s.IndexOf($needle, [System.StringComparison]::Ordinal)
      if ($i -ge 0) {
        $count = 1
        $j = $i
        while (($j = $s.IndexOf($needle, $j + $needle.Length, [System.StringComparison]::Ordinal)) -ge 0) { $count++ }
        $start = [Math]::Max(0, $i - 120)
        $firstCtx = ($s.Substring($start, [Math]::Min($ctxLen + 120, $s.Length - $start)) -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' ')
      }
      $needleRows += [pscustomobject]@{ '符号' = $needle; '含义' = $needleTable[$needle]; '命中' = $count; '首次命中上下文' = $firstCtx }
    }
    $s = $null; [GC]::Collect()

    $hasUploadChain   = (($needleRows | Where-Object '符号' -eq 'upload-credential').'命中' -gt 0) -and
                        (($needleRows | Where-Object '符号' -eq 'RepoSnapshotUploadClient').'命中' -gt 0)
    $forceIncludeGit  = (($needleRows | Where-Object '符号' -eq 'appendRootGitMetadataPaths').'命中' -gt 0) -and
                        (($needleRows | Where-Object '符号' -eq 'walkGitMetadataFiles').'命中' -gt 0)
    $gateExists       = (($needleRows | Where-Object '符号' -eq 'repoSnapshotIndexingEnabled===!').'命中' -gt 0)
    $legacyFeature    = (($needleRows | Where-Object '符号' -eq 'migrateLegacyRepoSnapshotRootDir').'命中' -gt 0)

    $asarResult = [pscustomobject]@{
      '扫描对象'     = (Get-HomePrefixRedacted $asarPath)
      '上传链路存在' = $hasUploadChain
      '.git 强制收录存在' = $forceIncludeGit
      '设置门控存在' = $gateExists
      '历史版本迁移痕迹' = $legacyFeature
      '判读' = '混淆代码保留了 a(变量,"函数名") 注解, 符号可检索; 命中即代码层证据'
    }
    Add-Section '步骤7 app.asar 符号命中' $needleRows '只列出结论行时可将上下文列忽略; -KeepRawContext 保留更长混淆代码摘录。'
  } else {
    $asarResult = [pscustomobject]@{ '扫描对象' = $asarPath; '结果' = '未找到 app.asar' }
  }
  Add-Section '步骤7 app.asar 取证结论' $asarResult
} else {
  Write-Host '[步骤7] 已按参数跳过 asar 扫描' -ForegroundColor DarkGray
}

# ---------------- 步骤8 时间线重建 ----------------

$events = @()
foreach ($ws in $workspaceSummaries) {
  $wsDir = Join-Path $checkpointsDir $ws.'目录(工作区哈希)'
  $sp = Join-Path $wsDir 'state.json'
  if (Test-Path $sp) { $events += [pscustomobject]@{ '时间' = (Get-Item $sp).CreationTime; '事件' = "工作区快照状态首次写入 ($(Get-P (Get-Content $sp -Raw | ConvertFrom-Json) 'workspacePath'))" } }
}
if (Test-Path $checkpointsDir) {
  $events += [pscustomobject]@{ '时间' = (Get-Item $checkpointsDir).CreationTime; '事件' = '快照功能首次落盘(checkpoints 目录创建)' }
}
if (Test-Path $installManifest) {
  $events += [pscustomobject]@{ '时间' = (Get-Item $installManifest).CreationTime; '事件' = '安装清单重建(更新/重装节点)' }
}
if (Test-Path $exePath) {
  $events += [pscustomobject]@{ '时间' = (Get-Item $exePath).CreationTime; '事件' = 'ZCode.exe 创建(安装/重装)' }
  $events += [pscustomobject]@{ '时间' = (Get-Item $exePath).LastWriteTime; '事件' = 'ZCode 程序文件更新' }
}
$timeline = @($events | Where-Object { $_.时间 } | Sort-Object 时间 |
  ForEach-Object { [pscustomobject]@{ '时间' = $_.时间; '事件' = $_.事件 } })
Add-Section '步骤8 本机时间线' $timeline

# ---------------- 结论评分 ----------------

$lastAcceptedAny = @($workspaceSummaries | Where-Object { $_.'服务端已接受(lastAccepted)' -ne '否' })
$pendingAny      = @($workspaceSummaries | Where-Object { $_.'待传任务存在' -eq '是' })
$gitIncluded     = @($manifestAnalyses | Where-Object { $_.'.git 内部文件收录数' -gt 0 })
$diskGitAny      = @($manifestAnalyses | Where-Object { $_.'磁盘真实 .git 目录数' -gt 0 })
$enabledBoth     = $false
if ($settingInfo.Count -gt 0) {
  $b1 = (Get-P $settingInfo[0] 'repoSnapshotIndexingEnabled')
  $b2 = (Get-P $settingInfo[0] 'repoSnapshotIndexingUserConfigured')
  $enabledBoth = (($b1 -eq $true) -or ($b1 -eq 'true')) -and (($b2 -eq $true) -or ($b2 -eq 'true'))
}

if ($asarResult -and (Get-P $asarResult '上传链路存在')) {
  Add-Finding 'CRITICAL' '本安装包含完整的"快照打包 → 服务端凭证 → OSS 直传"上传链路' 'app.asar 命中 upload-credential / RepoSnapshotUploadClient / repo-snapshot.tar.gz.enc'
}
if ($lastAcceptedAny.Count -gt 0) {
  Add-Finding 'CRITICAL' '已有快照被服务端接受(至少一次成功上传)' ("lastAcceptedManifestHash 非空的工作区: " + (($lastAcceptedAny | ForEach-Object { $_.'workspacePath' }) -join ', '))
}
if ($gitIncluded.Count -gt 0) {
  Add-Finding 'CRITICAL' 'manifest 收录了 .git 内部文件 → git 提交历史被打包' (($gitIncluded | ForEach-Object { "$($_.workspaceKey): $($_.'.git 内部文件收录数') 条" }) -join '; ')
}
if ($enabledBoth) {
  Add-Finding 'WARN' '快照捕获当前处于开启状态' 'repoSnapshotIndexingEnabled=true 且 repoSnapshotIndexingUserConfigured=true(双门控放行)'
}
if ($pendingAny.Count -gt 0) {
  Add-Finding 'WARN' '存在 pending 加密制品(上传未完成或重试中)' (($pendingAny | ForEach-Object { $_.'workspacePath' }) -join ', ')
}
if ($diskGitAny.Count -gt 0 -and $gitIncluded.Count -eq 0) {
  Add-Finding 'INFO' '磁盘存在 .git 仓库但本次快照未收录(工作区根非 git 仓库, 走降级遍历跳过 .git)' '注意: 若以 git 仓库根目录作为工作区, 代码会强制收录完整 .git(绕过二进制检查)'
}
if ($asarResult -and (Get-P $asarResult '.git 强制收录存在')) {
  Add-Finding 'INFO' '代码层确认 .git 强制收录设计: appendRootGitMetadataPaths + walkGitMetadataFiles, 且最终过滤器对 .git 段路径无条件放行' '与公开文章指控一致; .env*/id_rsa/*.pem/*.key/token/secret 类路径反而被排除'
}
if ($asarResult -and (Get-P $asarResult '历史版本迁移痕迹')) {
  Add-Finding 'INFO' '存在 repo-snapshots→checkpoints 目录迁移逻辑, 说明该机制并非当前版本新增' 'migrateLegacyRepoSnapshotRootDir'
}

# ---------------- 输出报告 ----------------

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$mdPath = Join-Path $ReportDir "zcode-audit-$stamp.md"
$jsPath = Join-Path $ReportDir "zcode-audit-$stamp.json"

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# ZCode 快照上传行为审计报告")
$md.Add("")
$md.Add("- 生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$md.Add("- 目标安装: $(Get-HomePrefixRedacted $ZCodeDir)")
$md.Add("- 数据目录: $(Get-HomePrefixRedacted $ZcodeDataDir)")
$md.Add("- 本报告为只读取证产物; 包含本机路径与少量文件名样例, 外发前请脱敏")
$md.Add("")
$md.Add("## 结论")
$md.Add("")
$md.Add((ConvertTo-MdTable $script:Findings))
$md.Add("")
foreach ($sec in $script:Sections) {
  $md.Add("## $($sec.title)")
  if ($sec.note) { $md.Add(""); $md.Add("> $($sec.note)") }
  $md.Add("")
  $md.Add((ConvertTo-MdTable $sec.items))
  $md.Add("")
}
$mdText = $md -join "`n"
$jsObj = [pscustomobject]@{
  generatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  zcodeDir    = (Get-HomePrefixRedacted $ZCodeDir)
  zcodeData   = (Get-HomePrefixRedacted $ZcodeDataDir)
  findings    = $script:Findings
  sections    = $script:Sections
}
$jsText = ($jsObj | ConvertTo-Json -Depth 8)

[System.IO.File]::WriteAllText($mdPath, (Get-HomePrefixRedacted $mdText), [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($jsPath, (Get-HomePrefixRedacted $jsText), [System.Text.UTF8Encoding]::new($false))

# ---------------- 控制台摘要 ----------------

Write-Host "`n========== 审计结论 ==========" -ForegroundColor White
$colorMap = @{ CRITICAL = 'Red'; WARN = 'Yellow'; INFO = 'Cyan'; PASS = 'Green' }
foreach ($f in $script:Findings) {
  Write-Host ("[{0}] {1}" -f $f.level, $f.claim) -ForegroundColor $colorMap[$f.level]
  Write-Host ("       依据: {0}" -f $f.evidence) -ForegroundColor DarkGray
}
if ($script:Findings.Count -eq 0) { Write-Host '[PASS] 未发现快照捕获/上传痕迹' -ForegroundColor Green }
Write-Host "`n报告已写入:" -ForegroundColor White
Write-Host "  $mdPath"
Write-Host "  $jsPath"
