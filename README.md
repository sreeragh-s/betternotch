# SortMyMac

A native macOS notch companion that groups related files by topic, then moves the resulting folders wherever you put them.

## Build and run

Requires macOS 14 or later and Xcode with Swift 6. There are no third-party package dependencies.

```sh
./scripts/build.sh
open build/SortMyMac.app
swift test
```

The build script produces an ad hoc signed local app with its own generated icon. Distribution outside this Mac requires your Developer ID signing and notarization. The app uses the bundle identifier `com.sortmymac.native` so it can coexist with other installed builds.

## Connect Cloudflare

1. Open Settings from the notch or menu bar, then select **Cloudflare**.
2. Enter the 32-character account ID and an API token with **Workers AI Read** permission for that account.
3. Save the token in Keychain and select **Test connection**. This sends a small diagnostic request containing no file data.

Requests use your account's Workers AI access and billing. No service credentials are bundled with the app. Account preferences use UserDefaults; the token uses macOS Keychain. Credentials, file contents, and model responses are not logged.

## Organize files

1. Select up to 50 regular local files in Finder and drag them near the notch. Drop onto **Organize**. You can also click the empty tray or choose **Add files…** from the menu bar.
2. Select **Organize**. Original files stay in place during analysis. Limited excerpts are extracted locally from text, Markdown, PDF, and RTF; images receive small previews. Other formats contribute metadata. Download cloud placeholders in Finder first. Folders, bundles, and symbolic links are excluded.
3. Review the folder cards. Edit a folder's name; right-click a file icon to move it into another group or a new folder. Extra files are accessible from the card's count menu.
4. Drag a folder's icon, or **Drag All Folders**, into a Finder folder or onto the Desktop. Click the drag control instead to use a native destination picker, including with VoiceOver. The app moves originals only when a destination is accepted. Finder controls icon placement and sorting.

The menu bar also exposes Settings, Recovery, and Quit. `⌘Return` organizes while the notch has keyboard focus. Escape cancels analysis or closes an idle panel; Escape during a native drag cancels that drag. Hover never activates the app.

## Privacy and grouping

Choosing Organize sends filenames, types, sizes, dates, up to 1,200 characters of extracted text per file, and small image previews to [Cloudflare Clef](https://developers.cloudflare.com/workers-ai/models/clef/). The app does not send absolute source paths. Previews are packed into bounded contact sheets with explicit cell coordinates. No data leaves the Mac merely because files were added to the tray.

Clef scores pairwise topic relationships through typed decisions, in batches of at most 64 questions and four sheets. Complete-link clustering requires every relationship between merged groups to score at least 0.8. Unknown or uncertain relationships do not imply a group. Folder names come from shared local keywords and remain editable; unmatched files go into **Other**. A 50-file session compares up to 1,225 relationships over 20 batches.

## Moves, recovery, and Undo

A persistent journal records file identity, source and destination paths, SHA-256 fingerprints, and transfer checkpoints. It lives at `~/Library/Application Support/SortMyMac/moves.json`; it contains metadata, not file contents or credentials. Do not remove this history while moves need recovery.

- Canceled outgoing drags leave source files untouched. Native file promises supply the final destination URL after an accepted drop.
- Same-volume moves use coordinated filesystem moves. Cross-volume transfers verify the copied bytes and unchanged source before source removal. Source removal checks identity and contents again inside file coordination.
- Files are never overwritten. Duplicate basenames receive numbered suffixes. The destination picker numbers existing folder names; native receivers provide their final collision-resolved folder URL. An unexpected existing promise destination is rejected safely.
- **Recovery & Undo…** lists completed and interrupted operations. Undo restores each file to its original path when safe, including after a restart. Partial operations can be undone independently.
- Changed or replaced destinations, occupied original paths, missing parent folders, and ambiguous crash states are preserved for review. Resolve the listed conflict, then retry Undo. Empty destination folders are removed with `rmdir`; folders containing user-added items are kept.

Quit is blocked while a move is active. If macOS or the process is interrupted, reopen Recovery. Network errors and canceled analysis do not move files.

## Development verification

```sh
./scripts/build.sh debug
open -n build/SortMyMac.app --args --smoke-test "/tmp/SortMyMac-QA-$(uuidgen)"
```

Debug-only smoke mode creates four disposable text files and isolated recovery history under a fresh temporary directory. It supplies deterministic test grouping without contacting Cloudflare and keeps the panel open for UI automation. Release builds contain no fixture service. Use its `destination/` folder to test export, cancel, and Undo.

See [UI practices](docs/UI-Practices.md) and [verification notes](docs/Verification.md).
