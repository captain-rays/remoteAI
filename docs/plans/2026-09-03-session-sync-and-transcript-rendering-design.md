# RemoteAI 会话同步与转录渲染设计

**日期：** 2026-09-03  
**状态：** 已批准  
**适用范围：** Mac Agent（Rust）、统一协议、iOS 客户端、Simulator 联调

## 1. 目标

让移动端按 provider 独立读取 Claude 与 Codex 的项目、会话列表和分页历史，并以统一界面展示用户消息、AI Markdown、代码块、可折叠推理、工具与错误。移动端可以新建或恢复非活动会话；已在其他端活动的会话保持只读，发送时返回明确的 `session_busy`。

本设计中的“同步”是进入页面或用户下拉刷新时进行的只读索引与历史读取，不包含文件自动同步、后台持续同步或凭据同步。

## 2. 核心架构

```text
Claude ~/.claude/projects/**/*.jsonl      Codex app-server/thread APIs
                  \                         /
                   ProviderAdapter 归一化
                            |
                   ConversationSummary
                   ConversationPage/events
                            |
                 REST 目录 + 加密 WS 业务操作
                            |
                    RemoteAgentClient
                            |
              provider-scoped cache / ViewModel
                            |
          用户气泡 + Markdown + 代码块 + 折叠推理
```

供应商原始 JSON 不直接进入视图。Rust 适配器只提取产品需要的字段，并转换为统一协议事件；iOS 渲染层不判断 Claude/Codex 私有格式。

## 3. 统一数据契约

### 3.1 会话索引

`ConversationSummary` 保持 provider、kind、projectPath、title、updatedAt、status，并新增可选的写入占用状态：

- `writeState`: `available | busy | unavailable`
- `writeBlockCode`: 稳定机器码，例如 `session_busy`

旧客户端忽略新增字段。列表和历史在 `busy` 时仍可读取。

### 3.2 历史与实时事件

历史页和实时流使用同一组 `ConversationEvent`：

- `conversation.user_message`
- `conversation.delta`
- `conversation.message_completed`
- `conversation.reasoning_delta`
- `conversation.reasoning_completed`
- `tool.started | tool.updated | tool.completed`
- `approval.requested | approval.resolved`
- `turn.completed | turn.failed | turn.interrupted`

消息 payload 至少包含稳定 `messageId`、`role` 和 `text`。推理 payload 至少包含 `reasoningId` 和 `text`，不得包含 provider 隐藏字段、认证信息或完整原始记录。

`conversation.history` 返回 `HistoryPage { events, nextCursor }`。游标只由对应 provider 解释；iOS 不解析游标内容。

## 4. Provider 数据来源

### 4.1 Claude

- 只读扫描 `~/.claude/projects/**/<session-id>.jsonl`。
- 会话 ID 使用文件名或记录中的 `sessionId`。
- 项目路径只取记录中的 `cwd`，不从有损 slug 反推。
- 标题取首条真实用户文本；更新时间取文件 mtime。
- 分页历史按文件偏移或稳定记录序号读取，不复制完整 transcript 到 Agent 数据库。
- stream-json 的用户输入由 iOS 乐观插入；Claude 的 `type=user` 工具结果不能误映射成用户聊天消息。
- thinking content block 归一化为 reasoning 事件。

### 4.2 Codex

- 会话列表与恢复继续使用 app-server `thread/list`、`thread/resume`。
- 项目分类取 thread 的真实 cwd；home 下的无项目会话归 daily，其余归 project。
- 历史通过 app-server thread/read 或现有只读本地索引读取，优先使用官方 app-server 接口。
- item 中的 user、agent message、reasoning、command/file/tool lifecycle 分别归一化为统一事件。
- 不读取或转发认证文件、Cookie、Token 或 provider 配置内容。

## 5. 单写入端与阻止信息

移动端读取列表和历史不获取写锁。执行 `conversation.resume` 或发送前，Agent 检查：

1. Agent 内是否已有该 provider/session 的活动进程或活动 turn；
2. provider 是否报告会话正在其他端运行；
3. 保守检测是否发现 transcript 正被外部进程持有或最后一轮未结束。

命中时不启动第二个 CLI 进程，返回加密业务错误：

```json
{
  "type": "error",
  "payload": {
    "code": "session_busy"
  }
}
```

iOS 显示“该会话正在其他端使用，当前只能查看记录。”不显示进程信息、文件路径或 provider stderr。无法可靠判定时采取保守阻止，不允许并发写入。

## 6. iOS 状态与发送行为

- 进入 Chat、Projects 或项目详情时先显示 provider-scoped 缓存，再刷新对应 provider 数据。
- 下拉刷新只更新当前 provider/项目，不跨 provider 混合。
- 打开会话后分页加载历史，历史事件与实时事件通过 messageId/sequence 去重。
- 用户点击发送时立即插入本地 user 气泡，状态为 `sending`。
- Agent 确认后状态变为 `sent`；网络或 provider 失败变为 `failed`，提供显式重试。
- 收到 `session_busy` 时保留草稿和用户气泡，但标记未发送并显示阻止原因。

## 7. 转录渲染

渲染器对两个 provider 完全共享：

- 用户消息：右侧气泡，保留发送中、失败、重试状态。
- AI 消息：左侧内容流，使用 Markdown 行内样式。
- 粗体：`**text**`。
- 次要/引用内容：灰色前景与引用边线。
- 行内代码：等宽字体与弱背景。
- 围栏代码块：独立背景、语言标签、横向滚动、复制按钮。
- 列表与链接：使用原生可访问控件。
- 推理：独立 DisclosureGroup，默认折叠；流式时可增量更新。

Markdown 分段器必须容忍流式阶段尚未闭合的代码围栏，未闭合部分先按普通文本展示，闭合后再转换为代码块，避免内容闪烁或丢失。

## 8. 错误与安全

- 只向移动端返回稳定错误码和通用文案。
- 不记录 prompt、推理正文、凭据、provider stderr 或配对材料。
- 历史读取设置单页记录数和单条文本大小上限。
- JSONL 中无法识别的事件转换为受限 `unsupported` 元数据，不把整条原始记录透传到手机。
- 文件传输仍必须由用户显式触发；本功能不增加任何自动同步。

## 9. 测试与验收

### 自动化

- Rust fixture：Claude/Codex 项目分类、标题、mtime 排序、分页历史、用户/AI/推理/代码事件、busy 阻止。
- 协议 fixture：Rust Serde 与 Swift Codable 固定向量。
- Swift 单元测试：乐观用户消息、失败重试、去重、分页合并、Markdown 分段、未闭合代码围栏、折叠推理。
- XCTest：provider 切换不串数据，项目→会话→历史导航，busy 会话阻止发送。

### 真实 Simulator

测试代理直接操作 iOS Simulator：

1. 选择 Claude，刷新项目与会话，打开历史；
2. 发送包含粗体、引用、列表和代码块的 query；
3. 验证用户气泡、AI 富文本、代码复制按钮和折叠推理；
4. 对活动会话发送，验证 `session_busy`；
5. 对 Codex 重复上述流程；
6. 截图并记录通过/失败项。

验收期间不使用权限绕过参数，不输出凭据，不创建自动同步路径。
