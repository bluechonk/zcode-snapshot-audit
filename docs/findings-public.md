# ZCode 快照上传行为取证报告（公开版）

> 这是一份脱敏后的公开取证报告，已移除本机路径、项目名、个人标识符等敏感信息。
> 原始取证环境：Windows x64，ZCode 桌面端 3.12.3.7463。

## 一句话结论

**ZCode 桌面端 3.12.3 (Windows x64) 存在静默打包工作区并上传至阿里云 OSS 的机制，代码层证据完整。本机曾处于开启状态并有至少一次成功上传；手动关闭设置开关后，验证无新捕获发生，证明开关有效。**

## 机制概述

ZCode（智谱 Z.ai 官方 AI 编程桌面端）在登录状态下会：

1. **打包工作区**：将工作区文件打包为 `repo-snapshot.tar.gz`
2. **信封加密**：使用 AES-256-CTR 加密制品，数据密钥用 RSA-OAEP 包给服务端公钥（**仅 ZCode 服务端可解密**）
3. **OSS 直传**：通过服务端签发的临时凭证，直传至阿里云 OSS
4. **触发时机**：每轮对话提交时（`captureStage: prompt`）
5. **`.git` 特殊处理**：当工作区根目录是 git 仓库时，代码会强制收录完整 `.git` 历史（含全部提交对象），且绕过二进制文件检查

## 代码层证据（app.asar 静态取证）

对 Electron 主进程包 `app.asar`（约 300MB）进行全量字符串检索，所有 13 个关键符号均命中：

| 符号 | 含义 | 命中数 |
|------|------|--------|
| `/api/v1/snapshot/upload-credential` | 上传凭证接口路径 | 7 |
| `RepoSnapshotUploadClient` | 上传客户端类 | 1 |
| `repo-snapshot.tar.gz.enc` | OSS 制品文件名 | 1 |
| `uploadPutObject` | OSS PUT 直传 | 1 |
| `uploadPostObject` | OSS POST 表单直传 | 1 |
| `x_oss_security_token` | 阿里云 OSS 临时凭证字段 | 4 |
| `appendRootGitMetadataPaths` | **强制收录工作区根 `.git`** | 1 |
| `walkGitMetadataFiles` | 递归遍历 `.git` 无内容过滤 | 1 |
| `shouldIncludeRepoSnapshotPath` | 快照收录最终过滤器 | 2 |
| `listGitVisibleFiles` | git ls-files 收集 | 1 |
| `looksLikeSecretPath` | secret 路径排除逻辑 | 1 |
| `migrateLegacyRepoSnapshotRootDir` | 历史版本迁移痕迹 | 1 |
| `markAcceptedManifest` | 上传被服务端接受后的状态写入 | 3 |
| `repoSnapshotIndexingEnabled===!` | 设置门控 | 1 |

### 关键代码逻辑

**`.git` 强制收录**：
- `appendRootGitMetadataPaths` 把工作区根 `.git` 全部内容递归加入候选
- 过滤器对 `.git` 段路径无条件放行，并绕过二进制检查
- 当工作区根不是 git 仓库时，`git ls-files` 失败 → 降级目录遍历 → 跳过一切名为 `.git` 的目录

**门控逻辑**：
```javascript
function gate(e){
  return e?.repoSnapshotIndexingEnabled===!0 
      && e.repoSnapshotIndexingUserConfigured===!0
}
```
两个开关同时为 `true` 时才放行捕获。schema 默认值为 `false`。

**排除规则**（存在但 `.git` 绕过）：
- `.env*`、`.npmrc`
- `id_rsa/id_dsa/id_ecdsa/id_ed25519`
- `*.pem/*.key/*.p12/*.pfx`
- 路径含 token/secret
- >1MB 大文件

## 数据层证据

### 设置状态
| 设置项 | 初始值 | 当前值 |
|--------|--------|--------|
| `repoSnapshotIndexingEnabled` | `true`（被显式打开） | **`false`**（已手动关闭） |
| `repoSnapshotIndexingUserConfigured` | `true` | `true` |

### 捕获记录
| 项 | 值 |
|------|------|
| 工作区 | `<非 git 仓库根目录>` |
| 收录文件数 | 2600 |
| 收录字节数 | ~35 MiB |
| `.git` 内部文件收录 | **0 条**（工作区根不是 git 仓库，触发降级遍历） |
| 磁盘真实 `.git` 目录 | 8 个（均未收录） |
| `.gitignore/.gitkeep` 等无害文件 | 16 条（被收录） |

### 上传状态
| 项 | 值 |
|------|------|
| `lastAcceptedManifestHash` | 非空（**至少一次上传已被服务端接受**） |
| pending 增量任务 | 存在，自捕获日起持续重试失败（failureCount=6） |
| 加密方式 | AES-256-CTR + RSA-OAEP-SHA256 |
| 凭证句柄 | 服务端签发 UUID（证明调用过 `/api/v1/snapshot/upload-credential`） |

## 开关有效性验证

手动关闭 `repoSnapshotIndexingEnabled` 后：
- checkpoints 目录自 09-18 捕获后再无新活动
- 至少数小时内没有新的捕获发生
- **结论：开关有效，可阻止新的快照打包上传**

## 外部时间线（OSINT）

| 时间 | 事件 |
|------|------|
| 2026-09-18 | ferstar 发布逆向分析文（源头）；glbai.com 发布深度分析文；知乎讨论帖出现；个别用户监控到累计大量上传 |
| 2026-09-18 深夜 ~ 09-19 | V2EX / Hacker News / CSDN / Habr 全面发酵 |
| 2026-09-19 | 智谱官方回应——归因"代码库索引 / Repo Wiki 模块初期默认开启"，称已修复、道歉、承诺开源 |

## 局限

1. 代码结论绑定 **3.12.3.7463 (Windows x64)**；混淆符号名在新版本可能变化，需重新扫描
2. 日志层预期为空（上传客户端为 debug 级日志），日志无命中不构成反证
3. 已上传内容无法撤回
4. 本次取证未涉及网络抓包（只读取证，不触发上传）

## 建议操作

1. **检查设置**：确认 `repoSnapshotIndexingEnabled` 为 `false`（设置 → 索引 → 关闭"代码库索引"）
2. **观察验证**：关闭后观察 `~/.zcode/v2/checkpoints/` 是否再生 pending 制品
3. **注意工作区选择**：以 git 仓库根目录作为工作区打开 ZCode 前，默认其 `.git` 全量历史会被打包上传
4. **已上传数据**：如已发生上传，数据已传至阿里云 OSS，无法撤回

## 参考

- [glbai.com：全网都在问 ZCode 把代码传去哪了（2026-09-18）](https://www.glbai.com/posts/zcode-silent-git-history-upload/)
- ferstar 的逆向分析（2026-09-18）及 [Habr 报道](https://habr.com)
- 智谱官方回应（2026-09-19）

> 本报告为独立取证记录，与智谱/Z.ai 无关。引用社区说法已标注来源。
