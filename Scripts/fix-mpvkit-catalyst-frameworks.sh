#!/bin/sh

set -eu

artifacts_root="${1:-}"
signing_identity="${2:-}"

if [ -z "$artifacts_root" ] || [ ! -d "$artifacts_root" ]; then
    exit 0
fi

find "$artifacts_root" -type d -name '*.framework' -print0 |
    while IFS= read -r -d '' framework; do
        case "$framework" in
            *maccatalyst/*.framework | "$artifacts_root"/*.framework) ;;
            *) continue ;;
        esac

        if [ -d "$framework/Versions" ]; then
            continue
        fi

        executable="$(basename "$framework" .framework)"
        if [ ! -f "$framework/$executable" ] || [ ! -f "$framework/Info.plist" ]; then
            continue
        fi

        mkdir -p "$framework/Versions/A/Resources"
        mv "$framework/$executable" "$framework/Versions/A/$executable"
        mv "$framework/Info.plist" "$framework/Versions/A/Resources/Info.plist"

        for directory in Headers Modules; do
            if [ -d "$framework/$directory" ]; then
                mv "$framework/$directory" "$framework/Versions/A/$directory"
                ln -s "Versions/Current/$directory" "$framework/$directory"
            fi
        done

        ln -s A "$framework/Versions/Current"
        ln -s "Versions/Current/$executable" "$framework/$executable"
        ln -s Versions/Current/Resources "$framework/Resources"

        if [ -n "$signing_identity" ]; then
            codesign --force --sign "$signing_identity" --timestamp=none "$framework"
        fi
    done
