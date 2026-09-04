# 文件浏览与显式传输 —— 开发文档

**日期：** 2026-09-04
**分支：** `integration/v1`
**状态：** 已审查，按修订契约开发中
**上位文档：** `2026-09-03-remote-ai-ios-client-design.md`（§5.4 文件、§7 文件传输、§8 安全）

---

## 1. 结论先行

文件浏览和文件传输**两端都没有接线**。不是 bug，是没写完。当前点"下载"会立刻失败，Files tab 是空的。

| 层 | 状态 | 证据 |
| --- | --- | --- |
| agent 端点基础逻辑 | ⚠️ 部分完成 | `/v1/files/*`、`/v1/transfers/*` 已存在，但绝对后代路径会被错误拒绝、preview 仍返回裸字节、冲突响应缺少 body |
| agent 接线 | ❌ **缺** | `GatewayState::set_file_root`（`agent/src/gateway.rs:93`）**全仓库无调用点** → `file_root` / `transfers` 恒为 `None` → 所有端点返回 **503** |
| iOS 客户端 | ❌ **缺** | `ios/RemoteAI/Core/RemoteAgentClient.swift:326-333` 共 8 个方法是抛异常的桩 |
| 既有测试 | ⚠️ 误导 | `TransferSuite`、`ManualTransferUITests` 全部打 `MockAgentClient`，真实链路一次都没跑过 |

这与 `refresh_provider_sessions` 是同一个模式：**定义了、有单测、生产代码里没人调**。做完本文档后，建议全局搜一遍还有没有第三个同类死代码。

### 1.1 集成审查修订（2026-09-04）

实现前按当前 Rust/Swift 类型重新核对后，原草案有以下接缝，必须以本节为准：

1. `FileEntry.path` 和 iOS 文件浏览器使用绝对路径，但 `TransferManager` 当前拒绝全部绝对路径，`FileService` 也只接受“恰好等于 root”的绝对路径。Agent 必须同时接受 `$HOME` 相对路径和 `$HOME` 内绝对路径，并拒绝 `..`、根目录外路径及 symlink escape。
2. `POST /v1/transfers/create` 使用 Rust `rename_all = "camelCase"`；规范字段是 `expectedSha256`、`conflictPolicy`。`sha256`/`conflict` 仅为兼容 alias，不新增 snake_case 契约。
3. `/v1/files/preview` 当前成功响应是裸字节，不是 JSON。v1 保持该端点为裸字节；iOS 用 `/metadata` 的大小与 preview 字节合成 `FilePreview`。
4. `TransferRequest` 当前没有 SHA-256 字段。必须增加 `expectedSha256`，由 `TransferCoordinator` 在 create 前计算，否则 Agent 的完成校验不会实际启用。
5. 下载端没有服务端 transfer session。下载 ticket、取消和 receipt 都是 iOS 本地状态；不得把本地 download ticket 发给 upload-only 的 cancel/finish 端点。
6. 下载端能计算并展示接收内容的 SHA-256，并以已知文件大小校验完整性；当前服务端没有提供源摘要，因此不能把本地摘要描述成与服务端摘要的密码学比对。端到端验收在 Mac 侧独立比较源/目标摘要。

---

## 2. 已定决策

**文件根目录 = `$HOME`。**

`TransferManager` / `FileService` 用根目录做 `PathOutsideRoot` 越界保护。设成 `/` 虽然符合设计文档"浏览整台 Mac"的字面表述，但会让越界保护形同虚设；设成 `$HOME` 覆盖全部真实使用场景（所有项目都在 `~` 下），且手机凭据泄露时暴露面可控。

**这是安全边界，不要为了"某个文件在 `/opt` 下"而临时放宽。** 需要放宽时改设计文档并单独评审。

---

## 3. Agent 侧任务（Rust）

### 3.1 接线 file root

**文件：** `agent/src/main.rs`（启动流程）、`agent/tests/gateway.rs` 或新增 `agent/tests/file_root_wiring.rs`

**先写失败测试**，覆盖生产启动路径而不是手动调用：

- 启动后 `GET /v1/files/list?path=$HOME` 返回 **200**，而不是 503
- `path` 指向 `$HOME` 之外（如 `/etc`）返回 **403**
- `POST /v1/transfers/create` 不再返回 503

> 现有测试之所以全绿却掩盖了这个 bug，是因为它们直接调 `state.set_file_root(...)`。新测试必须走真实启动路径。

**实现：** 从 `config.rs` 提取一个明确的 home 解析入口，由 `AgentConfig::default`、provider adapter 初始化和文件服务共同使用；不要调用已废弃的 `std::env::home_dir`，也不要在 `main.rs` 再实现一份不同的 fallback。在 adapters 接线的同处调用 `state.set_file_root(home)`。

为了可测试，生产启动接线应提取为由 `main` 调用的小函数；测试调用同一个函数后再通过 Router 请求端点，避免测试直接调用 `set_file_root` 造成假绿，也避免为了测试启动一个永不退出的固定端口进程。

### 3.2 统一文件路径契约

**文件：** `agent/src/files.rs`、`agent/src/transfers.rs`、对应 tests

- `.`、`work/a.txt` 等根目录相对路径解析到 `$HOME` 内。
- `$HOME` 和 `$HOME/work/a.txt` 等绝对路径保持可用。
- 其他绝对路径、规范化后逃逸的 `..`、以及指向根目录外的符号链接均返回 403。
- 返回给 iOS 的 `FileEntry.path` 和冲突 `existingPath` 始终是规范化后的绝对路径。

测试全部使用临时 root 及其 sibling，不访问真实 `$HOME`、`/etc` 或真实项目。

### 3.3 冲突响应带上现有文件信息（契约变更）

**当前：** 同名上传返回 **409，无 body**。

**问题：** 冻结契约要求冲突时向用户展示"目标已存在什么"再让其选择 `keep_both` / `overwrite`。只有一个 409 状态码，手机无法显示 `existingPath` / `existingSize`。

**要求：** 409 的 body 返回

```json
{ "error": "conflict", "existingPath": "/Users/kangle/x/README.md", "existingSize": 2048 }
```

`TransferError::Conflict { .. }` 已经携带信息，把它序列化出来即可（`transfer_error_response`，`agent/src/gateway.rs:532`）。

**替代方案**（若不想改 agent）：客户端收到 409 后再打一次 `/v1/files/metadata`。**不推荐**——多一次往返，且存在竞态。

---

## 4. iOS 侧任务（Swift）

**文件：** `ios/RemoteAI/Core/RemoteAgentClient.swift`

复用文件里已有的私有 REST 辅助 `rest(_:path:query:)`（第 105 行）。它已处理 origin 拼接、`x-remoteai-device` 头、2xx 校验、`ProtocolCoding.decoder` 解码。

⚠️ **`rest` 目前把所有非 2xx 一律抛成 `transport("http_<code>")`**，冲突路径需要区分 409。请扩展它（或新增一个变体）让调用方能拿到状态码，**不要**靠解析错误字符串。

### 4.1 精确 REST 契约（已在 `codex-cli 0.144.4` + 当前 agent 上核对）

所有路由都在 `ws_auth` 中间件后，必须带 `x-remoteai-device` 头。

**浏览**

| 方法 | 路径 | 入参 | 出参 |
| --- | --- | --- | --- |
| GET | `/v1/files/list` | `path`（必填）、`includeSensitive`（bool，默认 false） | `[FileEntry]` |
| GET | `/v1/files/metadata` | `path` | `FileEntry` |
| GET | `/v1/files/preview` | `path`、`maxBytes`（默认 65536） | `application/octet-stream` 裸字节 |

`FileEntry` 为 **camelCase**（Rust 侧 `#[serde(rename_all = "camelCase")]`），字段与 Swift `FileEntry` 一致：`path,name,kind,size?,modifiedAt?,hidden,readable,sensitive`。

错误：`403` 越界、`404` 不存在、`400` 其他、`503` 未接线。

**上传**

| 方法 | 路径 | body | 成功 |
| --- | --- | --- | --- |
| POST | `/v1/transfers/create` | `{"path": "<绝对或根相对目标路径>", "expectedSha256": "<hex>", "conflictPolicy": "keep_both"\|"overwrite"\|省略}` | `200 {"id","destination"}` |
| POST | `/v1/transfers/{id}/chunk` | `{"offset": <u64>, "data": "<base64>"}` | `204` |
| POST | `/v1/transfers/{id}/finish` | 无 | `204` |
| POST | `/v1/transfers/{id}/cancel` | 无 | `204` |

限制：单块 ≤ **4 MiB**（`MAX_CHUNK_BYTES`），HTTP body ≤ 8 MiB。
错误：`409` 冲突、`403` 越界、`404` 未知传输、`400` offset 非法/哈希不符、`503` 未接线。

**下载**

| 方法 | 路径 | 入参 | 成功 |
| --- | --- | --- | --- |
| GET | `/v1/transfers/download` | `path`、`start?`、`end?` | `200`（全量）或 `206`（带 range），**裸字节**非 JSON |

限制：单次 range ≤ **16 MiB**（`MAX_DOWNLOAD_BYTES`），非法 range 返回 `416`。

### 4.2 三处形状错位，必须桥接

客户端协议（`AgentClient`）与 agent REST 不是一一对应，这是泳道并行留下的接缝：

1. **`uploadChunk(transferId:index:data:)` vs `{offset,...}`**
   REST 要**字节偏移**而非块序号。`RemoteAgentClient` 需自己持有 `transferId → (chunkSize, destination, expectedSha256)` 映射，`offset = index × chunkSize`。chunkSize 由客户端决定（建议 **1 MiB**，远低于 4 MiB 上限），并写进 `createTransfer` 返回的 `TransferTicket.chunkSize`，使 `TransferCoordinator` 的分块与这里一致。`finish` 收到 204 后使用该映射合成 Swift `TransferReceipt`。

2. **`downloadChunk(transferId:index:)` 根本不需要 transfer id**
   下载是按 `path` 直接 ranged read，服务端**不建传输会话**。因此 `createTransfer(direction: .download)` **不要**打 `/v1/transfers/create`（那是上传专用，会误建上传会话甚至触发冲突）；应在客户端合成一个本地 ticket，存下 `path`、`byteCount` 与 `chunkSize`，供后续 `downloadChunk` 换算 `start`/`end`。下载 ticket 的 `cancel` 只删除本地映射，不调用 upload cancel；下载不调用 `finish`。
   > 已知历史坑：`MockAgentClient` 早期把 download 也当冲突处理过，已修（见 `MockAgentClientSuite` 里 "downloading an existing Mac file is not a conflict"）。真实客户端不要重蹈覆辙。

3. **`TransferTicket.conflict` vs HTTP 409**
   `createTransfer` 收到 409 时，**不得抛错**，而应返回一个 `conflict` 非空的 ticket，让 `TransferCoordinator` 停在 `.awaitingDecision`。这是冻结契约的硬要求：**未选择策略前不得写入目标**。

### 4.3 校验与完整性

- `TransferRequest` 增加可选 `expectedSha256`；上传 create 前由 `TransferCoordinator.checksum` 计算并放进 `expectedSha256`，让 Agent 校验（不符返回 400）。重试与冲突决策必须复用同一摘要。
- 下载以 listing/metadata 的 `size` 计算 `totalChunks`；完成时必须校验收到的总字节数等于该 size，再计算并展示 SHA-256。端到端测试另在 Mac 侧比较源文件与下载文件摘要。
- `filePreview` 先获取 metadata，再读取裸 preview bytes：`byteCount` 使用源文件 size，`truncated = sourceSize > receivedBytes`，非 UTF-8 时 `text = nil`。

---

## 5. 不可违反的约束（冻结契约）

来自 `2026-09-03-parallel-development-handoff.md` §3，实现时逐条对照：

- 传输**只能**由按钮、文件选择器确认或显式重试触发。**不得**新增 file watcher、定时任务、后台传输、生命周期回调触发。
- 同名上传必须显式选择 `keep_both` 或 `overwrite`，**不得**自动决定。
- 未选择策略前，目标文件**必须**保持不变。
- 离线时禁止发起传输。
- 路径越界必须被拒绝（服务端必须作为权威边界；客户端也在发请求前拦截明显的 `..`，但不得把客户端检查当成安全控制）。

**必须保持通过的既有回归测试：**
`TransferSuite` 里 "a coordinator that is merely alive transfers nothing"、
`ManualTransferUITests.testIdleAppNeverStartsATransfer`（空闲零传输的永久回归测试）。

---

## 6. 验收

### 自动化

```bash
rtk cargo fmt --all --check
rtk cargo clippy --workspace --all-targets -- -D warnings
rtk cargo test --workspace
rtk ./scripts/ios-check.sh      # 含逻辑测试和 UI 测试；数量以当次输出为准
```

### 真实 Simulator 联调（新增 opt-in UI 测试）

参照现有 `ios/RemoteAIUITests/RealCodexConversationUITests.swift` 的写法：
读 `SIMULATOR_HOST_HOME` + `~/Library/Application Support/RemoteAI/pairing.json` 决定是否 skip，并加进 `scripts/ios-check.sh` 的 `-skip-testing` 列表（配对密钥一次性，**一个 class 只放一个测试**）。

场景，全部针对 `$HOME` 下的一次性临时文件：

1. 浏览 `$HOME`，列表非空
2. 下载一个已知文件 → 校验 SHA-256 与源文件一致
3. 上传一个新文件 → agent 上出现，内容与 SHA-256 一致
4. 上传**同名**文件 → 出现冲突弹窗，且**此时目标文件未被修改**（用 mtime/内容双重断言）
5. 选 `keep_both` → 产生新文件名，原文件仍在
6. 选 `overwrite` → 目标被替换
7. 越界路径（使用测试 root 的 sibling）→ 被拒绝

> 测试产生的文件请放在 `$HOME` 下的临时目录并在结束时清理，不要污染真实项目。

---

## 7. 已知风险

- **agent 每次 catalog 请求都会重新索引 provider**（`refresh_provider`），文件端点不受影响，但联调时若发现整体变慢，先排除这一项再怀疑传输。
- **配对密钥一次性且用内存态存储**（`-RemoteAIPairingFile` 启动时 `usesEphemeralPairingStore = true`）。App 被杀掉后必须重启 agent 重新签发才能再连，写 UI 测试时每次运行前重启 agent。
- **`$HOME` 下有敏感目录**（`.ssh`、`.claude`、`.codex` 等）。`FileService` 有 `sensitive` 标记与 `includeSensitive` 开关，客户端已有"显式确认后才显示"的交互，**不要**在实现传输时绕过它。
- 下载单次上限 16 MiB、单块上限 4 MiB，大文件必须分多次 range 读取；`TransferCoordinator` 的进度条依赖 `totalChunks`，合成 download ticket 时要按文件大小正确计算。

---

## 8. 建议提交顺序

每步单独提交，先红后绿：

1. `feat(agent):` 以失败测试驱动统一 home 解析、生产 file-root 接线及绝对/相对路径契约
2. `feat(agent):` 以失败测试驱动 409 冲突 JSON（含 `existingPath` / `existingSize`）
3. `feat(ios):` 以失败测试驱动 REST 原始响应/状态码辅助与文件浏览/preview 桥接
4. `feat(ios):` 以失败测试驱动上传 create/chunk/finish/cancel、预提交 SHA-256 及 409 冲突路径
5. `feat(ios):` 以失败测试驱动下载本地 ticket、ranged read、本地 cancel、大小校验与摘要展示
6. `test(ios):` 新增 opt-in 真实 Simulator 传输 UI 测试
