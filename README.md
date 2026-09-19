# zcode-snapshot-audit

ZCode（智谱 Z.ai AI 编程桌面端）"静默打包工作区并上传"指控的**只读取证工具包**。

2026-09-19 在 ZCode 3.12.3 (Windows x64) 上完成的人工排查，已固化为可一键复跑的审计脚本 + 完整方法论。

## 结论（TL;DR）

- ✅ **机制存在**：`app.asar` 中有完整的「快照打包 → `/api/v1/snapshot/upload-credential` 取凭证 → 阿里云 OSS 直传 `repo-snapshot.tar.gz.enc` → callback」链路。
- ✅ **本机已开启且传过**：`state.json` 的 `lastAcceptedManifestHash` 非空（该字段仅在上传被服务端接受后写入）；捕获对象为工作区（2600 文件 / ~35 MiB），另含全局配置摘要与会话 prompt 文本。
- ⚠️ **加密不等于保密**：信封加密（AES-256-CTR），数据密钥用 RSA-OAEP 包给服务端公钥——只有 ZCode 服务端能解密。
- ❌ **`.git` 这次没被打包**：代码确实会强制收录工作区根 `.git` 的全部内容（含完整提交历史，绕过二进制检查）；但工作区根不是 git 仓库时走降级目录遍历，会跳过一切名为 `.git` 的目录。**以 git 仓库根目录作为工作区打开时，`.git` 全量历史会被打包上传。**
- ✅ **开关有效**：`repoSnapshotIndexingEnabled` 关闭后，验证无新捕获发生。

## 公开报告

已脱敏的取证报告：[docs/findings-public.md](docs/findings-public.md)

可直接用于社区分享、问题反馈或提交给厂商。

## 环境要求

- **Windows**（脚本路径逻辑绑定 `%LOCALAPPDATA%` / `%USERPROFILE%`，macOS/Linux 不适用）
- **PowerShell 7.0+**（脚本头部 `#Requires -Version 7.0`）
- 本机安装 ZCode 桌面端：默认 `%LOCALAPPDATA%\Programs\ZCode`；数据目录默认 `%USERPROFILE%\.zcode`，非默认位置用下述参数指定

## 使用

```powershell
# 完整审计（含 app.asar 字节扫描，需数十秒）
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/Invoke-ZCodeSnapshotAudit.ps1

# 快速模式（跳过 asar 扫描，只做数据层/设置/日志取证）
pwsh -NoProfile -File scripts/Invoke-ZCodeSnapshotAudit.ps1 -SkipAsarScan

# 保留 asar 命中处的更长混淆代码摘录
pwsh -NoProfile -File scripts/Invoke-ZCodeSnapshotAudit.ps1 -KeepRawContext
```

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-ZCodeDir` | `%LOCALAPPDATA%\Programs\ZCode` | ZCode 安装目录（非默认安装路径时指定） |
| `-ZcodeDataDir` | `%USERPROFILE%\.zcode` | ZCode 数据目录（checkpoints/setting.json/日志所在） |
| `-ReportDir` | 项目下 `reports/` | 审计报告输出目录 |
| `-SkipAsarScan` | 关 | 快速模式：跳过约 300MB 的 `app.asar` 字节扫描 |
| `-KeepRawContext` | 关 | asar 命中处保留更长的混淆代码摘录（供人工核对符号上下文） |
| `-NoRedact` | 关 | 报告不脱敏（默认报告中用户目录以 `~` 表示；**外发报告请保持默认**） |

脚本**只读**：不修改 ZCode 任何文件、不发起任何网络请求。报告输出到 `reports/zcode-audit-<时间戳>.md/.json`（该目录已 gitignore——报告含本机路径与文件名样例，**外发前请脱敏**）。

结论分级：`CRITICAL`（如快照已被服务端接受 / `.git` 被收录）、`WARN`（捕获开启中 / 有待传制品）、`INFO`（机制性事实）。

### 输出长什么样

运行结束后控制台会打印结论摘要，`reports/*.md` 按 8 步分节输出证据表格。结论节形如（路径已脱敏）：

```text
========== 审计结论 ==========
[CRITICAL] 已有快照被服务端接受(至少一次成功上传)
       依据: lastAcceptedManifestHash 非空的工作区: <工作区路径>
[WARN] 存在 pending 加密制品(上传未完成或重试中)
       依据: <工作区路径>
[INFO] 磁盘存在 .git 仓库但本次快照未收录(工作区根非 git 仓库, 走降级遍历跳过 .git)
       依据: 注意: 若以 git 仓库根目录作为工作区, 代码会强制收录完整 .git(绕过二进制检查)
```

MD 报告分节：结论 → 安装与版本 → checkpoints 工作区状态 → manifest 的 `.git` 收录分析 → 加密信封 → 设置开关 → 日志扫描 → app.asar 符号命中 → 本机时间线。

## 目录

```
├── LICENSE                                   # MIT 许可证
├── scripts/Invoke-ZCodeSnapshotAudit.ps1   # 一键审计（8 步：版本→state→manifest→信封→开关→日志→asar→时间线→评分）
├── docs/
│   ├── methodology.md                      # 完整取证方法论：判读标准、代码符号表、推理链、OSINT 方法
│   ├── findings-2026-09-19.md              # 首次排查的原始结论存档（含字节偏移）
│   ├── findings-2026-09-19-phase2.md       # 二次审计：设置变更后的验证
│   └── findings-public.md                  # 脱敏后的公开报告
└── reports/                                # 审计报告输出（已 gitignore）
```

## 局限

- 代码层结论绑定 3.12.3 (Windows x64)；新版混淆符号可能变化，需重新扫描——**新版验证方法**：升级 ZCode 后重跑脚本，并对照 [docs/methodology.md](docs/methodology.md) 的代码符号表核对命中情况。
- 日志层预期为空（上传走 debug 级日志），日志无命中不构成反证。
- 已上传内容无法撤回；本项目只负责检测与判读。

## 建议操作

1. 在设置中关闭"代码库索引"（或设置 `repoSnapshotIndexingEnabled=false`）
2. 观察 `~/.zcode/v2/checkpoints/` 是否再生 pending 制品验证生效
3. 以 git 仓库根目录作为工作区打开 ZCode 前，默认其 `.git` 全量历史会被打包上传

## 参考

- [glbai.com：全网都在问 ZCode 把代码传去哪了（2026-09-18）](https://www.glbai.com/posts/zcode-silent-git-history-upload/)
- ferstar 的逆向分析（2026-09-18，X/博客）及 [Habr 报道](https://habr.com)
- 智谱官方回应（2026-09-19）：归因"代码库索引 / Repo Wiki 模块初期默认开启"，称已修复、承诺开源

> 本项目为独立取证记录，与智谱/Z.ai 无关。

## 许可证

[MIT](LICENSE)
