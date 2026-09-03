#!/usr/bin/env bash
# Runs the RemoteAI iOS logic suites without requiring a full Xcode install.
#
# SwiftPM cannot link XCTest when only Command Line Tools are present, so the
# suites are plain Swift executed by `remoteai-tests`. When full Xcode is
# available, scripts/ios-check.sh additionally runs the XcodeGen + xcodebuild
# gate defined in the handoff document.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swift run --package-path ios remoteai-tests "$@"
