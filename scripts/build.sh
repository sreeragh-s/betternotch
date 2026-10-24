#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [ ! -f .build/native/lib/libSMMWhisper.dylib ] || [ ! -f .build/native/lib/libwebp.dylib ] || [ Native/WhisperBridge.cpp -nt .build/native/lib/libSMMWhisper.dylib ] || [ scripts/build-native-tools.sh -nt .build/native/lib/libSMMWhisper.dylib ]; then
    ./scripts/build-native-tools.sh
fi
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app="build/SortMyMac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/SortMyMac" "$app/Contents/MacOS/SortMyMac"
mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources/Licenses"
cp .build/native/lib/*.dylib "$app/Contents/Frameworks/"
cp -f .build/native/licenses/* "$app/Contents/Resources/Licenses/"
cp -f .build/checkouts/ZIPFoundation/LICENSE "$app/Contents/Resources/Licenses/ZIPFoundation-LICENSE"
for library in "$app/Contents/Frameworks/"*.dylib; do codesign --force --sign - "$library"; done
cp Resources/Info.plist "$app/Contents/Info.plist"
swift scripts/make-icon.swift build/SortMyMac.iconset
iconutil -c icns build/SortMyMac.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
echo "Built $PWD/$app"
