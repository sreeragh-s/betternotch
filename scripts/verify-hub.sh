#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh debug
qa="$PWD/.build/qa/BetterNotchUtilityQA.app"
mkdir -p "$(dirname "$qa")"
# This is a disposable app identity so it cannot attach to another running BetterNotch build.
if [ -d "$qa" ]; then rm -rf "$qa"; fi
cp -R build/BetterNotch.app "$qa"
mv "$qa/Contents/MacOS/BetterNotch" "$qa/Contents/MacOS/BetterNotchUtilityQA"
plutil -replace CFBundleIdentifier -string com.betternotch.native.utilityqa "$qa/Contents/Info.plist"
plutil -replace CFBundleExecutable -string BetterNotchUtilityQA "$qa/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string 'BetterNotch UI Test' "$qa/Contents/Info.plist"
plutil -replace CFBundleName -string 'BetterNotch UI Test' "$qa/Contents/Info.plist"
codesign --force --sign - "$qa"
if [ "$#" -gt 0 ]; then
    open -n "$qa" --args --smoke-test "/tmp/BetterNotch-QA-hub-$(uuidgen)" "$@"
else
    open -n "$qa" --args --smoke-test "/tmp/BetterNotch-QA-hub-$(uuidgen)"
fi
