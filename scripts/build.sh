#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app="build/SortMyMac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/SortMyMac" "$app/Contents/MacOS/SortMyMac"
cp Resources/Info.plist "$app/Contents/Info.plist"
swift scripts/make-icon.swift build/SortMyMac.iconset
iconutil -c icns build/SortMyMac.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
echo "Built $PWD/$app"
