# ZCode 快照上传行为取证方法论

> 本文档记录 2026-09-19 对 ZCode（智谱 Z.ai 官方 AI 编程桌面端）"静默打包工作区并上传"指控的完整排查逻辑。
> 全程遵循三条原则：**只读**（不修改被审计对象任何文件）、**不联网**（不触发任何上传）、**可复现**（每一步都有判读标准和代码依据）。
> 配套自动化脚本：`scripts/Invoke-ZCodeSnapshotAudit.ps1`。

## 背景

2026-09-18，开发者 ferstar 逆向 ZCode 桌面端后公开指控：ZCode 在登录状态下把整个工作区（含完整 `.git` 提交历史）打包加密，通过服务端签发的凭证直传阿里云 OSS，无禁用开关、隐私政策未披露。2026-09-19 智谱回应称问题源于"代码库索引"功能（Repo Wiki 模块初期默认开启），已修复并承诺开源。

取证目标：在自己机器上独立验证三件事——

1. 机制是否存在（代码层证据）；
2. 本机是否启用、是否已发生上传（数据层证据）；
3. `.git` 历史是否真的被打包（指控核心，需要代码与实测互相印证）。

## 阶段一：本机取证（8 步）

### 步骤 1：定位安装与版本

- 位置：`%LOCALAPPDATA%\Programs\ZCode`（Electron 应用），`ZCode.exe` 的 `VersionInfo` 给出 `ProductVersion / FileVersion`。
- 为什么：公开指控明确针对 **3.12.3**；版本不符则后续代码结论不能直接套用。
- 产出：版本号、`resources/app.asar` 是否存在及其大小（约 300MB 的主 JS 包，是代码取证的唯一对象）。

### 步骤 2：checkpoints 目录清点 + `state.json` 判读

数据目录 `%USERPROFILE%\.zcode\v2\checkpoints\<工作区哈希>\`。目录结构本身就是行为指纹：

```
<hash>/state.json
<hash>/manifests/<manifestHash>.json        # 收录文件清单(路径+大小)
<hash>/extra-manifests/<hash>.json          # 全局配置快照清单
<hash>/pending/<groupId>.tar.gz.enc         # 打包加密后的待传制品
<hash>/pending/<groupId>.envelope.json      # 加密信封
<hash>/tmp/                                 # 明文中间产物
```

`state.json` 字段判读表（核心）：

| 字段 | 含义 | 判读 |
| --- | --- | --- |
| `workspacePath` / `workspaceKey` | 被快照的工作区 | 确定取证范围 |
| `lastCompressedSize.encryptedSizeBytes / workspaceSizeBytes` | 上次制品加密大小 / 源工作区大小 | 量化泄露面 |
| **`lastAcceptedManifestHash`** | 服务端已接受的 manifest 哈希 | **仅在"上传被服务端接受"后由 `markAcceptedManifest` 写入。非空 = 至少一次成功上传** |
| `activeUpload` / `pendingUpload` | 在传 / 待传任务 | 任务存在 = 捕获已发生且尚未落定 |
| `attemptCount` / `failureCount` | 尝试/失败次数 | 长期 failure 且 pending 不清理 = 上传通道有问题 |
| `attribution.uploadCredentialHandle` | 服务端签发的凭证句柄（UUID） | **本地不可能凭空产生，存在即证明客户端真实调用过 `GET /api/v1/snapshot/upload-credential`** |
| `attribution.captureStage` | 捕获时机（如 `prompt`） | 每轮对话提示词时点触发捕获 |
| `kind` | `baseline`（全量）/ `increment`（增量） | 增量任务的 `baseManifestHash` 指向上一次被接受的 manifest |

关键推理链：`kind=increment` 且 `baseManifestHash` 非空 → 捕获时本地已有 `lastAcceptedManifestHash` → **在该次捕获之前已经有一次完整的成功上传**。这是"是否真的传出去过"的判定核心。

### 步骤 3：manifest 的 `.git` 收录分析（指控核心）

- 读取 `manifests/*.json`，对 `files[].path` 做两类正则：
  - 真实 `.git` 目录段：`(^|[\\/])\.git([\\/]|$)` —— 命中即 git 内部文件（objects/refs/…）；
  - 同形普通文件：`(^|[\\/])\.git(ignore|keep|modules|attributes|github)(/|$)` —— `.gitignore` 等，无害。
- 与磁盘对照：`Get-ChildItem <workspacePath> -Recurse -Force -Depth 4 -Filter .git -Directory`，得到"磁盘上有 N 个真实 `.git`，manifest 收录了 M 条"的对照表。
- **矛盾排查模板**（本次实证遇到）：代码强制收录 `.git`，但实测收录为 0。原因必须到代码里找：
  - `scanRepoSnapshot` 先跑 `git ls-files --cached --others --exclude-standard`；
  - **工作区根不是 git 仓库时该命令失败 → 降级为目录遍历 `walkFiles`，而降级遍历对一切名为 `.git` 的目录直接跳过**（`Mct/Pct = new Set([".git"])`）；
  - `appendRootGitMetadataPaths` 只追加**工作区根** `.git`，根目录没有 `.git` 就什么都不加。
  - 结论：**收录与否取决于工作区根是不是 git 仓库**。`<工作区根目录>` 这种"非 git 根 + 内嵌子仓库"的布局不会被收录 `.git`；把某个仓库根目录直接当工作区打开，完整 `.git`（含全部提交历史与对象）就会被打包。

### 步骤 4：extra-manifest 与加密信封判读

- `extra-manifests/*.json`：`global-configs` 组，打包 `settings.behavior.json` / `mcp.json` / `skills.json` 等全局配置（键名匹配 `api_key|access_token|secret|password|credential|cookie|token` 等的值会被正则脱敏后上传）。
- `pending/*.envelope.json`：`contentAlgorithm=aes-256-ctr`、`keyWrapAlgorithm=rsa-oaep-sha256`、`keyId=<服务端密钥版本>`、`encryptedDataKey`（数据密钥被服务端公钥包裹）。
- **判读**：这是信封加密而不是端到端加密——解密私钥只在 ZCode 服务端。"上传的是密文"不等于"ZCode 看不到你的代码"。

### 步骤 5：设置开关

读 `%USERPROFILE%\.zcode\v2\setting.json`：

- `repoSnapshotIndexingEnabled` 与 `repoSnapshotIndexingUserConfigured` **同时为 true** 才放行捕获（host 侧门控函数，形如 `e?.repoSnapshotIndexingEnabled===!0 && e.repoSnapshotIndexingUserConfigured===!0`）；
- 两键的 schema 默认值都是 `false`，出现 `true` 说明被显式打开过（首次启用引导或用户点击）；
- 排查建议：把 `repoSnapshotIndexingEnabled` 改为 `false`（或在 设置 → 索引 关闭"代码库索引"），随后观察 `checkpoints` 是否再产生新的 pending 制品来验证是否真的停了。

### 步骤 6：日志关键词扫描

对 `~\.zcode\v2\logs\*.log`（Electron 主进程）与 `~\.zcode\cli\log\*.jsonl`（CLI）扫描：`snapshot-upload`、`upload-credential`、`uploadCredential`、`aliyuncs`、`x_oss`、`repo-snapshot`、`repo_snapshot`。

- **预期结果为空**：上传客户端日志器是 debug 级，INFO 级日志不留网络痕迹。
- 注意区分干扰项：`git-checkpoint`（本地"改动回滚"RPC 通道）、`readSession 历史快照`、`getEntitlementSnapshot`（配额）都含 "snapshot/checkpoint" 字样但与上传无关。
- **日志为空不能反证没上传**——数据层证据（步骤 2）优先级更高。

### 步骤 7：app.asar 静态取证

原理：`app.asar` 内是压缩前 JS（307MB），虽经混淆，但 `a(变量,"函数名")` 形式的名称注解保留了大量可读符号。方法：latin1 全量载入为字符串（约 600MB 内存），`IndexOf` 定位关键词并截取上下文窗口。

关键符号表：

| 符号 | 含义 |
| --- | --- |
| `/api/v1/snapshot/upload-credential` | 上传凭证接口路径（响应需含 `oss.*`、`encryption.public_key`、`snapshot.snapshot_id`、`callback.*`） |
| `RepoSnapshotUploadClient` | 上传客户端类（`getUploadCredential` / `uploadPutObject` / `uploadPostObject`） |
| `repo-snapshot.tar.gz.enc` | OSS 直传的制品文件名 |
| `x_oss_security_token` / `x_oss_date` | 阿里云 OSS 临时凭证字段（证实"OSS 直传"而非走自家 API 中转） |
| `scanRepoSnapshot` | 扫描编排：`listGitVisibleFiles`（git ls-files）→ 失败则降级 `walkFiles` → `appendRootGitMetadataPaths` |
| `appendRootGitMetadataPaths` / `walkGitMetadataFiles` | **把工作区根 `.git` 全部内容递归追加进快照，无任何过滤** |
| `shouldIncludeRepoSnapshotPath(BeforeSample)` | 两级过滤器：symlink/依赖/缓存/构建产物/**secret 路径（`.env*`、`id_rsa`、`*.pem`、`*.key`、`*.p12`、含 token/secret）**/ >1MB 大文件被排除；**唯独 `.git` 段路径无条件放行且绕过二进制检查** |
| `migrateLegacyRepoSnapshotRootDir` | `repo-snapshots` → `checkpoints` 目录迁移，证明机制早于当前版本 |
| `markAcceptedManifest` | 上传被服务端接受后的状态写入点（清空 pending、记录 lastAccepted） |
| `repoSnapshotIndexingEnabled===!` | 设置开关的运行时门控（与 `UserConfigured` 联合判定） |

排除目录参考（降级遍历跳过）：`node_modules`、`.cache`、`.turbo`、`dist`、`build`、`out`、`.next`、`coverage`、Electron asar 相关。

### 步骤 8：本机时间线重建

收集 `CreationTime / LastWriteTime`：ZCode.exe（安装/更新）、`.zcode-install-manifest`（更新节点）、`checkpoints` 目录（功能首次落盘）、`state.json` 与 pending 制品（捕获发生点）。用于回答"我这台机器是什么时候开始的"。

## 阶段二：OSINT 时间线（定性"什么时候开始的事"）

检索路径：中文关键词（`ZCode 偷偷上传 .git`、`ZCode 智谱 回应`）+ 英文（`ZCode repo snapshot upload privacy`）+ 定向域（`site:news.ycombinator.com`）。按"源头 → 转载/讨论 → 官方回应"归并日期，注意相对时间（"14 小时前"）要折算为绝对日期。本次结论：

- **2026-09-18**：ferstar 逆向文发布（源头），火绒监控出现"单机 43GB 上传"说法；glbai.com 深度分析文同日发布；知乎当天出现讨论帖。
- **2026-09-18 深夜 ~ 09-19**：V2EX、Hacker News、CSDN、Habr 全面发酵。
- **2026-09-19**：智谱回应，归因"代码库索引 / Repo Wiki 模块初期默认开启"，称已修复、道歉、承诺开源。

## 判读矩阵速查

| 证据 | 结论强度 |
| --- | --- |
| `lastAcceptedManifestHash` 非空 | **成功上传已发生（最强数据层证据）** |
| `uploadCredentialHandle` 存在 | 已联系服务端换取上传凭证 |
| manifest `.git` 段收录 > 0 | git 历史在打包范围内（实测发生） |
| asar 命中上传链路符号 | 机制存在于本安装包（代码层证据） |
| 磁盘有 `.git` 但收录 0 | 本次未收录；工作区根是 git 仓库时会被收录 |
| 日志无命中 | 无信息量（预期为空），不作为反证 |

## 局限与注意事项

1. 代码结论绑定 **3.12.3 (Windows x64)**；混淆符号名在新版本可能变化，需重新检索。
2. 报告含本机路径与工作区文件名样例，**外发前脱敏**。
3. 已上传内容无法撤回；能做的是停用开关、删除 `checkpoints` 内容、观察是否再生。
4. 本项目仅为独立取证记录，与智谱/Z.ai 无关；引用社区说法时应标注来源与不确定性（如"43GB"为个别用户监控数据）。
