# Session Sync and Transcript Rendering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Synchronize Claude and Codex project/session/history metadata to iOS and render complete user/assistant/reasoning transcripts with native Markdown, code blocks, and single-writer protection.

**Architecture:** Each Rust provider adapter reads only its vendor-supported index/transcript source and normalizes it into the shared `ConversationSummary` and `ConversationEvent` protocol. The gateway exposes provider-scoped catalogs and paged encrypted history, while iOS uses one provider-neutral cache, optimistic send model, and shared transcript renderer. Resume/send is rejected with `session_busy` when another writer is active.

**Tech Stack:** Rust, Tokio, Serde, Axum, Claude stream-json, Codex app-server JSON-RPC, Swift 5.10, SwiftUI, XCTest, XcodeGen, iOS 17.5 Simulator.

---

## Global constraints

- Use `rtk` for every shell command.
- Use `superpowers:test-driven-development` for every behavior change.
- Agent lane may modify only `agent/**`, `protocol/**`, `scripts/agent-*`, and root Rust workspace files.
- iOS lane may modify only `ios/**`.
- Never add filesystem auto-sync, background transcript mirroring, permission bypass flags, or credential logging.
- Provider transcript bodies may be read on demand but must not be copied into Agent persistence.
- Make one small commit per task.

### Task 1: Freeze normalized session and reasoning protocol

**Files:**
- Modify: `agent/src/protocol.rs`
- Modify: `agent/tests/protocol_fixtures.rs`
- Modify: `protocol/fixtures/catalog.json`
- Modify: `protocol/fixtures/events.jsonl`
- Modify: `ios/RemoteAI/Core/ProtocolModels.swift`
- Modify: `ios/RemoteAITests/ProtocolFixtureSuite.swift`

**Step 1: Write failing Rust and Swift fixture tests**

Add fixtures proving:

```json
{
  "writeState": "busy",
  "writeBlockCode": "session_busy"
}
```

and events for `conversation.reasoning_delta` and `conversation.reasoning_completed` with `reasoningId` and `text`.

**Step 2: Verify RED**

Run:

```bash
rtk cargo test -p remote-ai-agent --test protocol_fixtures
rtk swift run --package-path ios remoteai-tests
```

Expected: decoding fails because write state and reasoning cases are missing.

**Step 3: Implement the minimal shared models**

Add optional summary fields for backward compatibility and explicit reasoning variants. Unknown event types must continue to decode as `unsupported`.

**Step 4: Verify GREEN**

Run both commands from Step 2. Expected: PASS.

**Step 5: Commit by lane**

```bash
rtk git add agent/src/protocol.rs agent/tests/protocol_fixtures.rs protocol/fixtures
rtk git commit -m "feat: define synchronized transcript protocol"
```

```bash
rtk git add ios/RemoteAI/Core/ProtocolModels.swift ios/RemoteAITests/ProtocolFixtureSuite.swift
rtk git commit -m "feat(ios): decode synchronized transcript protocol"
```

### Task 2: Build the Claude read-only session index

**Files:**
- Modify: `agent/src/adapters/claude.rs`
- Modify: `agent/tests/claude_adapter.rs`
- Create: `agent/tests/fixtures/claude/projects/project-a/session-a.jsonl`
- Create: `agent/tests/fixtures/claude/projects/project-b/session-b.jsonl`

**Step 1: Write failing tests**

Use a temporary Claude home and assert `list_conversations()`:

- recursively finds JSONL sessions;
- gets the session ID from the record/file name;
- gets project path from `cwd`, never from the slug;
- gets title from the first real user text;
- sorts by mtime descending;
- classifies home sessions as daily and other cwd values as project;
- ignores credentials/settings and malformed lines without exposing raw JSON.

**Step 2: Verify RED**

```bash
rtk cargo test -p remote-ai-agent --test claude_adapter list_conversations
```

Expected: current implementation returns an empty list.

**Step 3: Implement a bounded metadata scan**

Read only `projects/**/*.jsonl`. Stop parsing once the index fields are known; enforce a maximum line size. Do not store transcript bodies.

**Step 4: Verify GREEN**

```bash
rtk cargo test -p remote-ai-agent --test claude_adapter
```

**Step 5: Commit**

```bash
rtk git add agent/src/adapters/claude.rs agent/tests/claude_adapter.rs agent/tests/fixtures/claude
rtk git commit -m "feat: index Claude projects and sessions"
```

### Task 3: Page and normalize Claude history

**Files:**
- Modify: `agent/src/adapters/claude.rs`
- Modify: `agent/tests/claude_adapter.rs`
- Modify: `agent/tests/fixtures/claude/projects/project-a/session-a.jsonl`

**Step 1: Write failing tests**

Assert `load_conversation(id, cursor)` returns stable pages containing:

- user messages as `UserMessage`;
- assistant text as completed messages;
- thinking blocks as reasoning events;
- tool lifecycle without treating tool results as user chat;
- a stable next cursor and no duplicate item across pages.

**Step 2: Verify RED**

```bash
rtk cargo test -p remote-ai-agent --test claude_adapter load_conversation
```

Expected: inactive sessions are rejected.

**Step 3: Implement bounded JSONL pagination**

Resolve IDs only through the previously discovered index. Reject path traversal. Normalize allowed fields and discard provider-only raw payloads.

**Step 4: Verify GREEN**

```bash
rtk cargo test -p remote-ai-agent --test claude_adapter
```

**Step 5: Commit**

```bash
rtk git add agent/src/adapters/claude.rs agent/tests/claude_adapter.rs agent/tests/fixtures/claude
rtk git commit -m "feat: load paged Claude transcript history"
```

### Task 4: Complete Codex project and history normalization

**Files:**
- Modify: `agent/src/adapters/codex.rs`
- Modify: `agent/tests/codex_adapter.rs`
- Modify: `agent/tests/fixtures/codex/*.jsonl`

**Step 1: Write failing tests**

Fixture the app-server responses and assert:

- `thread/list` maps real cwd into daily/project summaries;
- `thread/read` or supported local metadata returns paged history;
- user messages, assistant text, reasoning, command/file/tool lifecycle normalize to shared events;
- provider credentials and raw configuration are absent.

**Step 2: Verify RED**

```bash
rtk cargo test -p remote-ai-agent --test codex_adapter
```

Expected: history/user/reasoning assertions fail.

**Step 3: Implement the smallest official-interface mapping**

Prefer Codex app-server APIs. Use local session JSONL only as a read-only fallback when the current CLI lacks the required read method.

**Step 4: Verify GREEN**

Run the command from Step 2. Expected: PASS.

**Step 5: Commit**

```bash
rtk git add agent/src/adapters/codex.rs agent/tests/codex_adapter.rs agent/tests/fixtures/codex
rtk git commit -m "feat: normalize Codex projects and history"
```

### Task 5: Enforce single-writer session occupancy

**Files:**
- Modify: `agent/src/adapters/mod.rs`
- Modify: `agent/src/adapters/claude.rs`
- Modify: `agent/src/adapters/codex.rs`
- Modify: `agent/src/gateway.rs`
- Modify: `agent/tests/provider_contract.rs`
- Modify: `agent/tests/gateway_business.rs`

**Step 1: Write failing tests**

Cover:

- list/history remain readable while busy;
- resume/send never starts a second writer;
- Agent-owned active process/turn marks busy;
- provider-detected external activity marks busy;
- uncertain external activity is conservatively busy;
- encrypted error code is exactly `session_busy` and contains no process path or stderr.

**Step 2: Verify RED**

```bash
rtk cargo test -p remote-ai-agent --test provider_contract --test gateway_business
```

**Step 3: Implement a provider-neutral availability API**

Expose a small availability method on `ProviderAdapter`. Claude combines Agent session state with bounded transcript/process checks. Codex combines active app-server turn state with supported thread status/open-handle evidence. Gateway checks it immediately before resume/send.

**Step 4: Verify GREEN**

Run the command from Step 2. Expected: PASS.

**Step 5: Commit**

```bash
rtk git add agent/src/adapters agent/src/gateway.rs agent/tests/provider_contract.rs agent/tests/gateway_business.rs
rtk git commit -m "feat: block concurrent session writers"
```

### Task 6: Expose provider-scoped refresh and paged history

**Files:**
- Modify: `agent/src/provider_wiring.rs`
- Modify: `agent/src/gateway.rs`
- Modify: `agent/tests/session_refresh.rs`
- Modify: `agent/tests/gateway.rs`
- Modify: `agent/tests/gateway_business.rs`

**Step 1: Write failing tests**

Assert explicit refresh updates only the requested provider, and `conversation.history` returns encrypted, provider-scoped pages with stable cursors. A Claude request must never return Codex records.

**Step 2: Verify RED**

```bash
rtk cargo test -p remote-ai-agent --test session_refresh --test gateway --test gateway_business
```

**Step 3: Implement refresh/history routing**

Keep list endpoints read-only. Do not add plaintext transcript bodies to logs, audit fields, or Agent persistence.

**Step 4: Verify GREEN**

Run the command from Step 2. Expected: PASS.

**Step 5: Commit**

```bash
rtk git add agent/src/provider_wiring.rs agent/src/gateway.rs agent/tests
rtk git commit -m "feat: serve synchronized session history"
```

### Task 7: Load and cache real catalogs/history on iOS

**Files:**
- Modify: `ios/RemoteAI/Core/RemoteAgentClient.swift`
- Modify: `ios/RemoteAI/Core/CacheStore.swift`
- Modify: `ios/RemoteAI/App/AppModel.swift`
- Modify: `ios/RemoteAI/Features/Conversations/ConversationViewModel.swift`
- Modify: `ios/RemoteAITests/AppModelSuite.swift`
- Modify: `ios/RemoteAITests/ConversationViewModelSuite.swift`

**Step 1: Write failing tests**

Assert provider switching, initial cached display, explicit refresh, project filtering, paged history merging, and messageId/sequence deduplication.

**Step 2: Verify RED**

```bash
rtk swift run --package-path ios remoteai-tests
```

Expected: RemoteAgentClient history and refresh behavior are missing.

**Step 3: Implement minimal client/cache wiring**

Use provider-scoped cache keys. Fetch only the visible provider/project. Preserve existing offline cache behavior and never cache credentials.

**Step 4: Verify GREEN**

Run the command from Step 2. Expected: PASS.

**Step 5: Commit**

```bash
rtk git add ios/RemoteAI/Core ios/RemoteAI/App ios/RemoteAI/Features/Conversations ios/RemoteAITests
rtk git commit -m "feat(ios): synchronize provider sessions and history"
```

### Task 8: Show optimistic user messages, failure, and retry

**Files:**
- Modify: `ios/RemoteAI/Features/Conversations/ConversationViewModel.swift`
- Modify: `ios/RemoteAI/Features/Conversations/EventViews.swift`
- Modify: `ios/RemoteAITests/ConversationViewModelSuite.swift`

**Step 1: Write failing tests**

Assert a tap on send immediately appends one user item with `sending`, acknowledgment changes it to `sent`, provider/network failure changes it to `failed`, retry reuses the local message without duplicating it, and `session_busy` preserves the draft while displaying the block message.

**Step 2: Verify RED**

```bash
rtk swift run --package-path ios remoteai-tests
```

**Step 3: Implement the minimal local delivery state machine**

Do not depend on Claude or Codex echoing the user input. Reconcile a later server user event by client message ID if one arrives.

**Step 4: Verify GREEN**

Run the command from Step 2. Expected: PASS.

**Step 5: Commit**

```bash
rtk git add ios/RemoteAI/Features/Conversations ios/RemoteAITests/ConversationViewModelSuite.swift
rtk git commit -m "feat(ios): show user messages and retry state"
```

### Task 9: Add shared Markdown, code, and reasoning rendering

**Files:**
- Create: `ios/RemoteAI/Features/Conversations/TranscriptRenderer.swift`
- Modify: `ios/RemoteAI/Features/Conversations/EventViews.swift`
- Modify: `ios/RemoteAI/Features/Conversations/ConversationView.swift`
- Create: `ios/RemoteAITests/TranscriptRendererSuite.swift`

**Step 1: Write failing parser/view-model tests**

Cover bold, quote/secondary text, lists, links, inline code, fenced code with language, multiple code blocks, an unclosed streaming fence, copy text, and reasoning default-collapsed state.

**Step 2: Verify RED**

```bash
rtk swift run --package-path ios remoteai-tests
```

Expected: transcript block parser and reasoning presentation are missing.

**Step 3: Implement the renderer**

Split fenced code blocks first; render prose with `AttributedString(markdown:)`. Render code using a monospaced horizontal `ScrollView`, language label, and explicit copy button. Render reasoning in a `DisclosureGroup` initially collapsed. Keep unfinished fences as prose until closed.

**Step 4: Verify GREEN**

```bash
rtk swift run --package-path ios remoteai-tests
rtk xcodegen generate --spec ios/project.yml --project ios
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -sdk iphonesimulator -configuration Debug build-for-testing
```

Expected: all pass and build succeeds.

**Step 5: Commit**

```bash
rtk git add ios/RemoteAI/Features/Conversations ios/RemoteAITests/TranscriptRendererSuite.swift
rtk git commit -m "feat(ios): render rich conversation transcripts"
```

### Task 10: Add deterministic UI acceptance coverage

**Files:**
- Modify: `ios/RemoteAIUITests/ProviderSeparationUITests.swift`
- Modify: `ios/RemoteAIUITests/ConversationUITests.swift`
- Modify: `ios/RemoteAI/Core/MockAgentClient.swift`

**Step 1: Write failing UI tests**

Cover Claude and Codex project/list/history navigation, provider separation, user bubble, bold text, code block/language/copy button, collapsed reasoning disclosure, retry state, and busy-session blocking.

**Step 2: Verify RED**

```bash
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' test
```

Expected: new accessibility assertions fail.

**Step 3: Add deterministic fixtures and accessibility identifiers**

Fixtures must remain local and contain no provider credentials. Keep production behavior unchanged.

**Step 4: Verify GREEN**

Run the command from Step 2. Expected: PASS.

**Step 5: Commit**

```bash
rtk git add ios/RemoteAIUITests ios/RemoteAI/Core/MockAgentClient.swift
rtk git commit -m "test(ios): cover synchronized rich transcripts"
```

### Task 11: Run real Claude and Codex Simulator acceptance

**Files:**
- Modify only if a verified defect requires a TDD fix in the owning lane.

**Step 1: Start the real Agent and tunnel safely**

Use the owner-only pairing file. Do not put pairing payloads in process arguments or logs.

**Step 2: Install and launch the latest iOS build**

Use iOS 17.5 Simulator and the explicit pairing-file bootstrap.

**Step 3: Operate the Simulator directly**

The testing agent must click provider tabs, refresh lists, open projects/sessions, type a query, tap send, expand reasoning, inspect code formatting, and use the copy button. Capture screenshots for Claude and Codex.

**Step 4: Verify single-writer rejection**

Open a session on the desktop provider first, then attempt mobile send. Expected: readable history plus `session_busy`; no second provider process starts.

**Step 5: Run final verification**

```bash
rtk cargo fmt --all -- --check
rtk cargo clippy --workspace --all-targets -- -D warnings
rtk cargo test --workspace
rtk swift run --package-path ios remoteai-tests
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' test
```

Apply `superpowers:verification-before-completion` before declaring the feature complete.
