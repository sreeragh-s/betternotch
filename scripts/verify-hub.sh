#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh debug
qa="$PWD/.build/qa/SortMyMacUtilityQA.app"
mkdir -p "$(dirname "$qa")"
# This is a disposable app identity so it cannot attach to another running SortMyMac build.
if [ -d "$qa" ]; then rm -rf "$qa"; fi
cp -R build/SortMyMac.app "$qa"
mv "$qa/Contents/MacOS/SortMyMac" "$qa/Contents/MacOS/SortMyMacUtilityQA"
plutil -replace CFBundleIdentifier -string com.sortmymac.native.utilityqa "$qa/Contents/Info.plist"
plutil -replace CFBundleExecutable -string SortMyMacUtilityQA "$qa/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string 'SortMyMac UI Test' "$qa/Contents/Info.plist"
plutil -replace CFBundleName -string 'SortMyMac UI Test' "$qa/Contents/Info.plist"
codesign --force --sign - "$qa"
if [ "$#" -gt 0 ]; then
    open -n "$qa" --args --smoke-test "/tmp/SortMyMac-QA-hub-$(uuidgen)" "$@"
else
    open -n "$qa" --args --smoke-test "/tmp/SortMyMac-QA-hub-$(uuidgen)"
fi
