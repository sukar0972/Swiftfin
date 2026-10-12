#!/usr/bin/env bash
set -euo pipefail

TASK_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_DERIVED_DATA="${1:?Pass the DerivedData directory from an existing Catalyst build}"
TASK_MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
TASK_APP_FRAMEWORKS="$TASK_DERIVED_DATA/Build/Products/Release-maccatalyst/Swiftfin Mac.app/Contents/Frameworks"
TASK_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swiftfin-mpv-lifetime-tests.XXXXXX")"
trap 'rm -rf "$TASK_TEST_DIR"' EXIT

# MPVKit's libmpv is static, so include its FFmpeg/rendering dependencies too.
TASK_FRAMEWORK_FLAGS=()
TASK_STATIC_LIBRARIES=()
for TASK_FRAMEWORK in "$TASK_DERIVED_DATA"/SourcePackages/artifacts/mpvkit/*/*.xcframework/ios-arm64_x86_64-maccatalyst/*.framework; do
    [ -d "$TASK_FRAMEWORK" ] || continue
    case "$TASK_FRAMEWORK" in
        *-GPL/* | *Libsmbclient*) continue ;;
    esac
    TASK_FRAMEWORK_FLAGS+=(-F "$(dirname "$TASK_FRAMEWORK")" -framework "$(basename "$TASK_FRAMEWORK" .framework)")
done
for TASK_LIBRARY in "$TASK_DERIVED_DATA"/SourcePackages/artifacts/mpvkit/*/*.xcframework/ios-arm64_x86_64-maccatalyst/*.a; do
    [ -f "$TASK_LIBRARY" ] || continue
    case "$TASK_LIBRARY" in
        *-GPL/*) continue ;;
    esac
    TASK_STATIC_LIBRARIES+=("$TASK_LIBRARY")
done

# Link the real libraries from an existing build; do not build an app bundle.
xcrun swiftc -swift-version 5 \
    -target "$(uname -m)-apple-ios16.6-macabi" \
    -sdk "$TASK_MAC_SDK" \
    -F "$TASK_MAC_SDK/System/iOSSupport/System/Library/Frameworks" \
    "${TASK_FRAMEWORK_FLAGS[@]}" \
    "${TASK_STATIC_LIBRARIES[@]}" \
    -framework UIKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
    -framework CoreVideo -framework CoreFoundation -framework CoreMedia \
    -framework CoreText -framework Metal -framework VideoToolbox \
    -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ \
    -Xlinker -rpath -Xlinker "$TASK_APP_FRAMEWORKS" \
    "$TASK_PROJECT_ROOT/Shared/Objects/MediaPlayerManager/MediaPlayerProxy/MPVPlayerLifetime.swift" \
    "$TASK_PROJECT_ROOT/Tests/MPVPlayerLifetimeTests.swift" \
    -o "$TASK_TEST_DIR/lifetime-tests"
"$TASK_TEST_DIR/lifetime-tests"
