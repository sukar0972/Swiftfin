#!/usr/bin/env bash
set -euo pipefail

TASK_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
TASK_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swiftfin-fullscreen-tests.XXXXXX")"
trap 'rm -rf "$TASK_TEST_DIR"' EXIT

# Compile a standalone regression runner, not an application bundle.
xcrun swiftc -swift-version 5 \
    -target "$(uname -m)-apple-ios16.6-macabi" \
    -sdk "$TASK_MAC_SDK" \
    -F "$TASK_MAC_SDK/System/iOSSupport/System/Library/Frameworks" \
    "$TASK_PROJECT_ROOT/Swiftfin/Extensions/MacPlayerFullScreen.swift" \
    "$TASK_PROJECT_ROOT/Tests/MacPlayerFullScreenTests.swift" \
    -o "$TASK_TEST_DIR/fullscreen-tests"
"$TASK_TEST_DIR/fullscreen-tests"
