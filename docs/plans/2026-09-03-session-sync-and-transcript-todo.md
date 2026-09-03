# 会话同步与移动端转录渲染 TODO

**日期：** 2026-09-03
**状态：** 待办（backlog，尚未开工）
**上位文档：** `2026-09-03-remote-ai-ios-client-design.md`

三条来自真机/模拟器联调后的用户需求。每条都已定位到根因，可直接开工。

---

## 1. Claude 的项目与会话需要同步（泳道 A）

### 现状

`agent/src/adapters/claude.rs:240` 直接返回空列表，所以手机上永远是
"No Claude chats yet"：

```rust
async fn list_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
    Ok(Vec::new())
}
```

恢复能力已经就绪：`command_spec` 里已有 `--resume <session_id>`。

### 数据来源（已验证）

桌面 App（Code 标签）与终端 `claude` **共用同一份存储**：
`~/.claude/projects/<slug>/<session-uuid>.jsonl`。

建索引所需字段全部可得：

| 字段 | 来源 |
| --- | --- |
| 会话 ID（`--resume` 用） | 文件名 / 记录里的 `sessionId` |
| 项目路径 | 记录里的 `cwd` |
| 标题 | 首条 `type == "user"` 消息 |
| 更新时间 | 文件 mtime |

**不要用目录名反解路径。** slug 把 `/` 和 `.` 都压成 `-`
（`-Users-kangle-remoteAICli--claude-worktrees-claude-ios-v1`），无法无损还原；
必须读记录里的 `cwd`。

### 待办

- [ ] 实现 `list_conversations`：扫描 `~/.claude/projects/**`，按 `cwd` 归项目
- [ ] 只读索引：不复制 transcript 正文、不落任何凭据（遵守设计文档第 8 节）
- [ ] `load_conversation` 目前要求 session 处于 active（`"session is not active"`），
      需支持从 `.jsonl` 读取历史分页

### 未决问题（开工前必须先定）

**桌面 App 正打开的会话，手机 `--resume` 同一个 session id 会怎样？**
手机会另起一个 `claude --print` 进程续同一个会话，两个进程可能同时追加同一个
`.jsonl` → 可能分叉或互相覆盖。设计文档未覆盖。

需先用一次性会话验证 `--resume` 的写入行为，再在三种策略里选：
只读展示 / 只允许恢复未打开的会话 / 接受分叉。

### 分类副作用

`ClaudeMapper` 按 `cwd` 分类（home = daily，其他 = project）。桌面 App 的 Code
会话永远绑定目录，因此 Claude 的会话会**全部**落进「项目」，「聊天」tab 对
Claude 基本为空。需要决定是否调整分类规则。

---

## 2. 移动端对话记录：缺用户消息 + 渲染过于简陋（泳道 B）

### 2a. 用户自己的消息不显示

两个独立原因，都要改：

1. `ConversationViewModel.send()` 发送后**不本地插入**用户消息，只等
   `conversation.user_message` 事件。
2. 该事件永远不会来：Claude 适配器把 stream-json 的 `"user"` 映射成了
   **ToolCompleted**（`claude.rs:108`）——在 `--print` 流里 `user` 承载的是
   工具结果，用户本轮输入根本不会被回显。

**结论**：客户端必须在发送时乐观插入自己的消息（失败时标记未送达 + 可重试），
不能依赖服务端回显。

- [ ] `send()` 乐观插入 user 气泡，与失败重试状态联动
- [ ] 复核 `claude.rs:108` 的 `"user"` 映射是否符合预期（工具结果 vs 用户消息）

### 2b. AI 消息渲染要接近 Claude Code 的呈现

现状是纯文本：`EventViews.swift:13` 只有 `Text(item.text)`，没有任何富文本。

目标（按用户要求）：

- [ ] **推理过程可折叠** —— 需要先确认 thinking 内容是否出现在 stream-json 里
      （`stream_event` 的 thinking content block），以及适配器是否透传
- [ ] **代码块** —— 等宽字体、独立背景、横向滚动、可复制，最好带语言标签
- [ ] **加粗 / 标灰** —— 即基础 Markdown 行内样式（`**bold**`、次要文字降级）
- [ ] 列表、行内 `code`、链接等常见 Markdown

实现提示：iOS 17 的 `AttributedString(markdown:)` 能覆盖行内样式，但**不支持
围栏代码块**，需要自行按 ``` 分段后分别渲染。流式增量下要注意：未闭合的
```` ``` ```` 在 token 到齐前不能误判。

---

## 3. Codex 同 1 与 2

- [ ] **列表**：与 Claude 不同，Codex 的 `list_conversations` **已实现**
      （`codex.rs:200`，走 app-server 的 `thread/list`）。需实测手机上是否真的
      有数据，再决定是否补项目归类。
- [ ] **用户消息**：核对 Codex 适配器是否回显用户轮次；若不回显，2a 的客户端
      乐观插入方案对两个 provider 通用。
- [ ] **渲染**：2b 完全共享，渲染层不区分 provider。

---

## 边界说明

第 1 条与第 3 条的列表部分属于 `agent/**`（泳道 A）；第 2 条与渲染属于
`ios/**`（泳道 B）。本文件写在 `docs/`，是并行开发阶段之外的共享区域。
