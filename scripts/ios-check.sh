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

    echo
    echo "==> xcodebuild test (iPhone 16 simulator)"
    xcodebuild \
        -project ios/RemoteAI.xcodeproj \
        -scheme RemoteAI \
        -destination 'platform=iOS Simulator,name=iPhone 16' \
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
