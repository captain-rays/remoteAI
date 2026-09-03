#!/usr/bin/env bash
# Lane B completion gate.
#
# Runs everything this Mac can run, then runs the XcodeGen + xcodebuild gate
# from the handoff document if — and only if — full Xcode and xcodegen are
# present. When they are not, the Xcode gate is reported as NOT RUN rather than
# silently skipped. Pass --require-xcode to make a missing toolchain fatal.
set -euo pipefail

require_xcode=0
if [ "${1:-}" = "--require-xcode" ]; then
    require_xcode=1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

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

    # The handoff document names iPhone 16, which only exists from Xcode 16.
    # Prefer it, but fall back to any available iPhone so the gate is runnable
    # on an older Xcode instead of failing with "destination not found".
    simulator="${REMOTEAI_SIMULATOR:-}"
    if [ -z "$simulator" ]; then
        for candidate in "iPhone 16" "iPhone 15" "iPhone SE (3rd generation)"; do
            if xcrun simctl list devices available | grep -q "^    $candidate ("; then
                simulator="$candidate"
                break
            fi
        done
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
