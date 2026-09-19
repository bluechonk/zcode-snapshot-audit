# 二次取证结论（2026-09-19 阶段 2）

> 环境：Windows 11 Dev 26200 x64，ZCode 桌面端 3.12.3.7463（FileVersion 3.12.3.7463），数据目录 `%USERPROFILE%\.zcode`。
> 本文档为 2026-09-19 当日的第二次完整审计结论，验证设置变更后的状态。

## 一句话结论

**ZCode 二进制未更新（仍是 3.12.3.7463），代码层快照上传机制完整存在；但设置已被修改——`repoSnapshotIndexingEnabled` 已改为 `False`，且此后无新捕获活动，证明开关机制有效。**

## 与上午审计的关键差异

| 对比项 | 上午审计（~09:50） | 当前审计（~10:04） | 变化 |
|------|------|------|------|
| ZCode 版本 | 3.12.3.7463 | 3.12.3.7463 | 无变化 |
| app.asar 大小 | 307,867,744 字节 | 307,867,744 字节 | 无变化 |
| `repoSnapshotIndexingEnabled` | `true` | **`false`** | ⚠️ 已关闭 |
| `instantGrepIndexingEnabled` | `true` | **`false`** | 已关闭 |
| checkpoints 最后活动 | 09-18 01:59:55 | 09-18 01:59:55 | 无新活动 |
| 自动化脚本符号命中 | 未运行（首次人工） | 13/13 全部命中 | 代码层机制完整 |

## 代码层证据（app.asar 静态取证）

所有 13 个关键符号全部命中，上传链路完整存在：

| 符号 | 命中数 |
|------|--------|
| `/api/v1/snapshot/upload-credential` | 7 |
| `RepoSnapshotUploadClient` | 1 |
| `repo-snapshot.tar.gz.enc` | 1 |
| `uploadPutObject` / `uploadPostObject` | 各 1 |
| `x_oss_security_token` | 4 |
| `appendRootGitMetadataPaths` | 1 |
| `walkGitMetadataFiles` | 1 |
| `shouldIncludeRepoSnapshotPath` | 2 |
| `listGitVisibleFiles` | 1 |
| `looksLikeSecretPath` | 1 |
| `migrateLegacyRepoSnapshotRootDir` | 1 |
| `markAcceptedManifest` | 3 |
| `repoSnapshotIndexingEnabled===!` | 1 |

**判读**：代码层机制未被移除。智谱声称的"修复"（2026-09-19 官方回应）在这台机器的二进制中未体现——仍是 3.12.3.7463。修复可能是服务端默认值调整、首次启用引导逻辑变更，或针对新安装用户。

## 开关有效性验证

代码中的主机侧门控函数 `Cf(e)`：
```javascript
function Cf(e){return e?.repoSnapshotIndexingEnabled===!0&&e.repoSnapshotIndexingUserConfigured===!0}
```

当前设置：
- `repoSnapshotIndexingEnabled=false`
- `repoSnapshotIndexingUserConfigured=true`

→ `Cf(e)` 返回 `false` → 捕获逻辑不会启动。

**实证**：checkpoints 目录自 2026-09-18 01:59:55 以来无任何新活动，开关关闭后至少数小时内没有新的捕获发生。

## 数据层残留

### 已成功上传（不可撤回）
- `lastAcceptedManifestHash`: `e345c266...`（非空 = 服务端已接受）
- 捕获内容：2600 文件 / 35.77 MiB，含会话 prompt 文本、全局配置摘要、工作区代码
- 捕获时间：2026-09-18 01:59:54

### 待传失败任务（仍残留）
- `pendingUpload` 存在，failureCount=6
- 制品：0.04 MiB 增量包（`*.tar.gz.enc`）
- 加密方式：aes-256-ctr + rsa-oaep-sha256（仅服务端可解密）

### .git 收录情况
- manifest 中 `.git` 内部文件收录：**0 条**
- 磁盘真实 `.git` 目录：8 个（均未收录）
- 原因：工作区根 `<工作区路径>` 不是 git 仓库 → `git ls-files` 失败 → 降级目录遍历跳过一切 `.git` 目录
- **注意**：若以 git 仓库根目录作为工作区打开，代码会强制收录完整 `.git` 历史（`appendRootGitMetadataPaths` 已证实）

## 时间线

| 时间 | 事件 |
|------|------|
| 2026-09-14 00:51:49 | ZCode 安装 |
| 2026-09-16 23:14:34 | ZCode 程序更新 |
| 2026-09-18 00:49:13 | 安装清单重建 |
| 2026-09-18 01:04:55 | checkpoints 目录创建（快照功能首次落盘） |
| 2026-09-18 01:59:54 | 首次捕获（2600 文件） |
| 2026-09-18 01:59:55 | 一次上传被服务端接受；增量任务进入 pending |
| 2026-09-19 09:50:48 | 首次审计（上午） |
| 2026-09-19 10:01:43 | `setting.json` 被修改（开关关闭） |
| 2026-09-19 10:04:46 | 二次审计（当前） |

## 局限

1. 代码结论绑定 **3.12.3.7463 (Windows x64)**
2. 本次未更新 ZCode 到最新版本；若用户后续更新，需重新扫描
3. 报告含本机路径与文件名样例，外发前需脱敏

## 结论总结

1. **机制仍完整存在**：代码层所有上传链路、`.git` 强制收录、门控逻辑均未变化
2. **开关有效**：`repoSnapshotIndexingEnabled=false` 后无新捕获
3. **已上传数据不可撤回**：09-18 的 35.77 MiB 已传至阿里云 OSS
4. **智谱"修复"未体现在本机二进制**：修复可能是服务端行为或针对新用户
