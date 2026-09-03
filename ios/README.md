# RemoteAI iOS client (lane B)

SwiftUI client for the RemoteAI Mac agent. Built and tested against
`MockAgentClient`, independent of the Rust agent branch.

## Layout

| Path | Contents |
| --- | --- |
| `RemoteAI/App` | Entry point, `AppModel`, dependency graph |
| `RemoteAI/Core` | Protocol v1 models, agent client contract, mock agent, crypto, cache, transfers |
| `RemoteAI/Features` | Shell, conversations, projects, files, pairing, settings |
| `TestKit` | Dependency-free assertion + runner primitives |
| `RemoteAITests` | Suite bodies (plain Swift, no XCTest) |
| `RemoteAITestRunner` | `remoteai-tests` executable that runs the suites |
| `RemoteAIXCTests` | One XCTest bundle file that runs the same suites under Xcode |
| `RemoteAIUITests` | XCUITest suites (need a simulator) |
| `project.yml` | XcodeGen spec for the app + test targets |

## Running the tests

```bash
./scripts/ios-test.sh
```

Works with Command Line Tools alone. SwiftPM cannot link `XCTest` without full
Xcode, so the suites are plain Swift executed by `remoteai-tests`; the same
bodies run under XCTest via `RemoteAIXCTests/SuiteBridgeTests.swift` once Xcode
is installed.

Full gate, including the Xcode part when it is available:

```bash
./scripts/ios-check.sh
```

It prints `XCODE GATE: NOT RUN` rather than passing silently when Xcode or
XcodeGen is missing. Use `--require-xcode` in CI to make that fatal.

## Product rules this code enforces

- The provider switch clears the previous AI's rows before loading the new ones;
  filtering happens in `AppModel`, not in a view.
- Codex and Claude keep separate project records even for the same folder.
- Daily chats are never bound to a project; project sessions always are.
- Approvals offer exactly `allow_once` and `deny`.
- Offline is read-only: cached lists are visible, mutations are refused.
- Transfers start only from an explicit user action. A same-name upload stops
  and waits for `keep_both` or `overwrite`. `MockAgentClient.transferRequestCount`
  makes "an idle app transfers nothing" an assertable fact.
