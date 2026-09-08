#!/usr/bin/env bash
# Lane B completion gate.
#
# Runs everything this Mac can run, then runs the XcodeGen + xcodebuild gate
# from the handoff document if — and only if — full Xcode and xcodegen are
# present. When they are not, the Xcode gate is reported as NOT RUN rather than
# silently skipped. Pass --require-xcode to make a missing toolchain fatal.
set -euo pipefail

# Xcode builds the SwiftPM package into DerivedData and caches it. Adding a
# type to RemoteAIKit and then running the gate can therefore fail with
# "cannot find <type> in scope" from the test bundle while `swift build`
# succeeds — the package it compiled against is the cached one. `--clean`
# removes that cache; it costs a few minutes and is the answer whenever the
# Xcode gate disagrees with the logic suites about what exists.
require_xcode=0
clean=0
for argument in "$@"; do
    case "$argument" in
        --require-xcode) require_xcode=1 ;;
        --clean) clean=1 ;;
    esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [ "$clean" -eq 1 ]; then
    echo "==> removing ios/.derivedData"
    rm -rf ios/.derivedData
fi

echo "==> swift build (RemoteAIKit + suites)"
swift build --package-path ios

echo
echo "==> RemoteAI logic suites"
swift run --package-path ios remoteai-tests

echo
have_xcodegen=0
have_xcodebuild=0
command -v xcodegen >/dev/null 2>&1 && have_xcodegen=1
xcodebuild -version >/dev/null 2>&1 && have_xcodebuild=1

if [ "$have_xcodegen" -eq 1 ] && [ "$have_xcodebuild" -eq 1 ]; then
    echo "==> xcodegen generate"
    xcodegen generate --spec ios/project.yml

    # A booted simulator wins: it is the one whose runtime this Xcode actually
    # installs onto, and a hard-coded model list goes stale every Xcode release
    # — the gate failed with "destination not found" once the iPhone 15s were
    # left behind on an older runtime.
    simulator="${REMOTEAI_SIMULATOR:-}"
    if [ -z "$simulator" ]; then
        simulator="$(xcrun simctl list devices booted \
            | sed -n 's/^    \(iPhone[^(]*\) (.*/\1/p' | sed 's/ *$//' | head -1)"
    fi
    if [ -z "$simulator" ]; then
        # Nothing booted: take the newest available iPhone rather than a name
        # frozen into this script.
        simulator="$(xcrun simctl list devices available \
            | sed -n 's/^    \(iPhone[^(]*\) (.*/\1/p' | sed 's/ *$//' | tail -1)"
    fi
    if [ -z "$simulator" ]; then
        echo "==> XCODE GATE: NOT RUN"
        echo "    no available iPhone simulator found (xcrun simctl list devices available)"
        [ "$require_xcode" -eq 1 ] && exit 1
        exit 0
    fi

    echo
    echo "==> xcodebuild test ($simulator simulator)"
    # Pin DerivedData to the worktree. The shared default location is keyed by
    # project name, so a sibling worktree's cached package build leaks in and
    # fails the compile with stale type signatures.
    xcodebuild \
        -project ios/RemoteAI.xcodeproj \
        -scheme RemoteAI \
        -destination "platform=iOS Simulator,name=$simulator" \
        -derivedDataPath ios/.derivedData \
        -skip-testing:RemoteAIUITests/RealAgentConversationUITests \
        -skip-testing:RemoteAIUITests/RealCodexConversationUITests \
        -skip-testing:RemoteAIUITests/RealCodexChatUITests \
        -skip-testing:RemoteAIUITests/RealClaudeChatWriteUITests \
        -skip-testing:RemoteAIUITests/RealClaudeToolUseUITests \
        -skip-testing:RemoteAIUITests/RealAgentTranscriptUITests \
        -skip-testing:RemoteAIUITests/RealAgentSessionSyncUITests \
        -skip-testing:RemoteAIUITests/RealDesktopChatWriteUITests \
        -skip-testing:RemoteAIUITests/RealFileTransferUITests \
        test
else
    echo "==> XCODE GATE: NOT RUN"
    [ "$have_xcodegen" -eq 0 ] && echo "    missing: xcodegen (brew install xcodegen)"
    [ "$have_xcodebuild" -eq 0 ] && echo "    missing: full Xcode (xcode-select -s /Applications/Xcode.app/Contents/Developer)"
    echo "    The iOS unit-test bridge and the XCUITest suites were NOT executed."
    if [ "$require_xcode" -eq 1 ]; then
        echo "    --require-xcode was passed, so this is a failure."
        exit 1
    fi
fi
