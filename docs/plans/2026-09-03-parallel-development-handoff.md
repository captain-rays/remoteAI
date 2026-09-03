# RemoteAI Parallel Development and Integration Contract

**日期：** 2026-09-03  
**用途：** Codex 与 Claude 在独立 Git worktree 中并行开发，由主任务统一审查、合并和验收。  
**上位文档：** `2026-09-03-remote-ai-ios-client-design.md`、`2026-09-03-remote-ai-ios-client-implementation.md`

## 1. 并行策略

并行开发分为三个泳道：

| 泳道 | 负责人 | 范围 | 可修改路径 |
| --- | --- | --- | --- |
| A · Mac Agent | Codex 新任务 | Rust Agent、统一协议、加密网关、Codex/Claude 适配器、目录与传输服务 | `agent/**`、`protocol/**`、`scripts/agent-*`、根目录 Rust 工程文件 |
| B · iOS Client | Claude | SwiftUI App、移动端协议模型、模拟传输、日常会话/项目/文件/设置界面 | `ios/**`、`scripts/ios-*` |
| C · 集成验收 | 当前 Codex 主任务 | 审查两条分支、合并、修复契约接缝、端到端与安全验收 | 合并后按需修改；并行开发阶段不提前占用 A/B 文件 |

泳道 A 和 B 必须在不同 worktree 和不同分支工作。禁止两边修改对方所有权路径；需要变更公共协议时，只提交“契约变更提案”，由集成验收泳道统一决定。

建议分支：

- `codex/agent-v1`
- `claude/ios-v1`
- `integration/v1`

## 2. Worktree 规则

从包含本文件的同一个基线提交创建两个 worktree：

```bash
rtk git worktree add ../remoteAICli-codex -b codex/agent-v1
rtk git worktree add ../remoteAICli-claude -b claude/ios-v1
```

如果分支或目录已经存在，先用 `rtk git worktree list` 检查，不得删除或覆盖现有工作。每个泳道只在自己的 worktree 中提交，提交保持小而可审查，不得直接合并到默认分支。

## 3. 冻结的 v1 产品契约

以下规则在并行阶段冻结：

- 顶部必须显式切换 `Codex | Claude`，默认 Codex，之后记住上次选择。
- 两个 AI 的列表绝不混合。
- 每个 AI 内部分为 `daily` 与 `project`：日常会话不绑定项目；项目用规范化 Mac 路径标识，并包含自己的会话列表。
- 同一个已有会话不能中途更换 AI。
- 文件只允许用户显式上传或下载；禁止自动同步、文件监听、定时传输和生命周期触发传输。
- 上传冲突必须显式选择 `keep_both` 或 `overwrite`。
- AI 授权只允许 `allow_once` 或 `deny`，禁止永久允许和绕过权限。
- Mac 离线时手机仅可读取缓存，禁止消息、授权与未缓存文件操作。
- WorkBuddy 不在 v1 范围。

## 4. 冻结的协议模型

所有业务消息使用版本化 envelope：

```json
{
  "protocolVersion": 1,
  "messageId": "uuid",
  "kind": "request | response | event",
  "requestId": "uuid-or-null",
  "sequence": 42,
  "conversationId": "provider-native-id-or-null",
  "type": "conversation.delta",
  "payload": {}
}
```

核心枚举：

```text
ProviderId       = codex | claude
ConversationKind = daily | project
ApprovalDecision = allow_once | deny
ConnectionState  = disconnected | connecting | paired | online | recovering
```

v1 请求类型：

```text
provider.status
conversations.daily.list
projects.list
projects.conversations.list
conversation.history
conversation.start
conversation.resume
conversation.send
conversation.interrupt
approval.decide
files.list
files.metadata
files.preview
transfers.create
transfers.chunk
transfers.finish
transfers.cancel
audit.list
diagnostics.get
device.revoke
```

v1 事件类型：

```text
conversation.started
conversation.user_message
conversation.delta
conversation.message_completed
tool.started
tool.updated
tool.completed
approval.requested
approval.resolved
turn.completed
turn.failed
turn.interrupted
provider.status_changed
```

未知事件必须映射为 `unsupported(rawType)` 并安全忽略，不得导致连接或 App 崩溃。协议主版本不兼容时返回 `upgrade_required`。

## 5. 数据结构最低字段

### ProviderStatus

```text
provider, available, executablePath?, version?, reason?
```

### ConversationSummary

```text
id, provider, kind, title, projectId?, projectPath?, updatedAt, status
```

### ProjectSummary

```text
id, provider, canonicalPath, displayPath, title, updatedAt, available
```

即使 `canonicalPath` 相同，Codex 与 Claude 也必须产生不同的项目 ID。

### ApprovalRequest

```text
id, provider, conversationId, category, title, detail, cwd?, risk?, createdAt
```

### FileEntry

```text
path, name, kind, size?, modifiedAt?, hidden, readable, sensitive
```

## 6. 泳道 A：Codex 新任务说明

### 交付目标

完成可独立运行和测试的 Mac Agent。使用模拟客户端验证协议，不依赖 iOS 分支。

### 模块拆分

1. Rust workspace、配置、SQLite 与 provider discovery。
2. 协议 schema、跨语言中立 JSON fixtures 和错误码。
3. P-256 ECDH、HKDF-SHA256、AES-256-GCM、单次二维码配对、防重放计数器。
4. Axum localhost HTTP/WebSocket gateway、心跳、重连和事件补发。
5. Provider trait 与 deterministic mock adapter。
6. Codex app-server adapter。
7. Claude stream-json adapter。
8. provider-specific 日常会话与项目目录。
9. 安全文件浏览与显式分块传输。
10. 审计、诊断、Cloudflare 配置说明和 Agent 测试客户端。

### 强制边界

- 不修改 `ios/**`。
- Agent 只监听 `127.0.0.1`。
- 不读取、复制或记录供应商凭据。
- 不以任何参数绕过 Codex/Claude 权限。
- 文件测试只能使用经过断言验证的临时目录。
- 不添加任何自动同步机制。

### 完成门禁

```bash
rtk cargo fmt --all --check
rtk cargo clippy --workspace --all-targets -- -D warnings
rtk cargo test --workspace
```

同时提供一个本地模拟客户端，能走完配对、列目录、列会话、模拟流式事件、授权与手动文件传输。

## 7. 泳道 B：Claude 任务说明

### 交付目标

完成可在 iOS Simulator 运行和测试的 SwiftUI 客户端。通过 `MockAgentClient` 验证全部界面与状态，不依赖 Rust Agent 分支。

### 模块拆分

1. XcodeGen 工程、App shell、测试 targets。
2. Swift 协议模型、envelope、错误与未知事件兼容。
3. CryptoKit/Keychain 抽象与测试向量接口；真实向量在集成阶段与 Rust 对齐。
4. `AgentClient` protocol、`MockAgentClient`、WebSocket transport 状态机。
5. 顶部 Codex/Claude 切换器和四个 tab。
6. 当前 AI 的日常会话列表。
7. 当前 AI 的项目列表、项目详情和项目会话。
8. 对话流、流式消息、工具事件、停止按钮与授权卡片。
9. Mac 文件浏览、预览、iOS 文件选择器、显式上传/下载、冲突确认。
10. 配对、连接状态、诊断、审计与撤销设置。

### 强制边界

- 只修改 `ios/**` 和 `scripts/ios-*`。
- 不修改 Rust、`protocol/**` 或根目录工程文件。
- App 首次默认 Codex，之后保存最后选择。
- 切换 AI 后必须立即清除旧 AI 的可见列表，再加载新数据。
- 离线模式只读。
- 只提供 `allow_once` 和 `deny`。
- 任何传输只能由按钮、文件选择确认或明确重试触发。
- 必须有一条自动测试：App 空闲时 `MockAgentClient` 收到的 transfer 请求数始终为 0。

### 完成门禁

```bash
rtk xcodegen generate --spec ios/project.yml
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' test
```

如果本机没有完整 Xcode，仍需完成代码与测试，但必须明确标记“未运行”，不得声称测试通过。

## 8. 给 Claude 的可复制启动提示

```text
你在独立 worktree 的 claude/ios-v1 分支上开发 RemoteAI iOS 客户端。

先完整阅读：
1. docs/plans/2026-09-03-remote-ai-ios-client-design.md
2. docs/plans/2026-09-03-remote-ai-ios-client-implementation.md
3. docs/plans/2026-09-03-parallel-development-handoff.md

只负责 handoff 文档的“泳道 B”，只允许修改 ios/** 和 scripts/ios-*。严格使用测试驱动开发和小提交。使用 MockAgentClient 独立完成 UI，不等待 Rust Agent。两个 AI 的列表必须分开，每个 AI 又必须区分日常会话和项目；文件传输只能由用户显式触发，绝不实现自动同步。

完成后提供：提交列表、修改文件列表、实际运行过的测试及原始结果、未完成项和已知风险。不要合并默认分支。
```

## 9. 集成顺序

1. 从共同基线创建 `integration/v1`。
2. 审查泳道 A 的提交，再合并 `codex/agent-v1`。
3. 运行 Rust 全部门禁；失败则停止，不继续叠加 iOS 分支。
4. 审查泳道 B 的提交，再合并 `claude/ios-v1`。
5. 以 `protocol/v1/fixtures` 为唯一跨语言契约源，修正 Swift/Rust 编解码差异。
6. 运行 iOS 单元测试与 UI 测试。
7. 运行 mock 端到端测试。
8. 最后才运行真实 Codex/Claude 只读 smoke test和实体 iPhone 蜂窝网络验收。

禁止使用直接复制整个目录的方式集成；必须通过 Git 合并或逐提交 cherry-pick 保留来源。

## 10. 主任务验收清单

### 代码审查

- 两个泳道是否越界修改文件。
- 是否存在硬编码凭据、个人路径、隧道 Token 或未脱敏 fixture。
- 是否存在权限绕过参数。
- 是否存在文件 watcher、定时任务、后台传输或隐式覆盖。
- 未知协议事件是否安全降级。
- Provider、daily/project 过滤是否在数据层而不只是 UI 层完成。

### 自动门禁

```bash
rtk cargo fmt --all --check
rtk cargo clippy --workspace --all-targets -- -D warnings
rtk cargo test --workspace
rtk xcodegen generate --spec ios/project.yml
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' test
```

### 必须通过的端到端场景

1. 配对成功，错误/过期/复用二维码失败。
2. Codex 与 Claude 列表切换后互不残留。
3. 两个 AI 都分别展示日常会话和项目会话。
4. 对话流式事件顺序正确，断线后不重不漏。
5. 授权只允许一次或拒绝，手机可停止任务。
6. 文件上传/下载必须由用户触发；空闲状态零传输。
7. 同名文件未选择策略前不改变目标。
8. 路径穿越、重放消息、撤销设备和明文业务帧均被拒绝。
9. Cloudflare 只转发到 localhost Agent，供应商凭据不离开 Mac。

任何一项失败都不得标记 v1 验收通过。

## 11. 交付给主任务的格式

Codex 和 Claude 分别提交以下内容：

```text
Branch:
Base commit:
Final commit:
Owned files changed:
Commits:
Tests actually run:
Raw test summary:
Known limitations:
Contract changes requested:
```

主任务收到两份交付信息后进行 diff 审查、合并、全量测试和实体设备验收，不依据开发者的“已完成”陈述直接通过。
