# SortMyMac

A native macOS notch hub for file tools, visual previews, meeting recording, local transcripts, and Codex activity.

## Build and run

Requires macOS 14 or later, Xcode with Swift 6, Git, and Python 3. The first build fetches pinned ZIPFoundation, whisper.cpp, and libwebp sources. If CMake is absent, it installs a pinned copy in `.build/native/tooling`; it does not change your system Python or require Homebrew. Native engines are bundled in the app.

```sh
./scripts/build.sh
open build/SortMyMac.app
swift test
```

The build script produces an ad hoc signed local app with its own generated icon. Distribution outside this Mac requires your Developer ID signing and notarization. The app uses the bundle identifier `com.sortmymac.native` so it can coexist with other installed builds.

## Notch, shelf, and file actions

Hover opens Home with Record Meeting, Meetings, File Tools, Shelf, Recent Results, and Activity. Dragging files temporarily replaces Home with a drop target. Canceling the drag restores the previous view. Dropping only adds references; no processing starts until you choose an action.

The shelf and recent results survive restarts. Right-click a file to preview, open, reveal in Finder, save a copy, copy to the clipboard, or remove its shelf reference. Missing/replaced files have Locate and Remove actions. Removing a reference never deletes the source; managed results have a separate Move to Trash command. Pin folders under Destinations for explicit Copy or Move operations.

Settings → Permissions shows microphone and screen/system audio access, offers explicit permission requests, and opens the relevant macOS privacy panes. Files & Folders settings are linked separately. Status refreshes when you return to the app; opening this page never starts recording or requests access automatically.

- **Images:** resize, convert (JPEG/PNG/HEIC/TIFF/WebP where available), compress with a target size, crop/rotate, remove background, and OCR. Drag directly on the image to crop; move the selection or resize its edges/corners, with optional ratio locks and rotation. The editor starts with one large canvas; encoded results add Result/Compare views with zoom. Format/quality and presets live in compact menus. JPEG requires a white/black transparency background.
- **Audio/video:** scrub a waveform or thumbnail timeline; set and loop one start/end interval; trim, convert, compress video, extract audio, or make a GIF (20 seconds maximum). Generate an encoded preview for actual file size and playback, then Keep results or Save. Audio outputs are M4A/WAV/AIFF; native video outputs are MP4/MOV.
- **PDF/documents:** merge with file ordering, extract/reorder/rotate pages, split into one PDF per page, OCR scanned pages, and create PDFs from text/RTF/images. Image-based PDF compression explicitly flattens text and annotations; ordinary page operations preserve them.
- **File management:** preview batch renames and undo them in Activity; create/preview/extract ZIPs; review exact duplicates without automatic deletion.
- **Presets:** save settings from an editor, then append transformation steps from another editor to build a chain. The chain validates every step and uses the same preview/export path. Configure a macOS Shortcut in Settings → Local AI to expose custom file actions, including Office conversions.

Transformations create new files. Outputs are staged and validated before publication; expensive jobs queued during a recording wait until recording/transcription yields. Activity exposes real per-file progress, cancellation, results, retries, and interrupted jobs.

## Codex in the notch

The notch shows **only pending questions and permission requests**. Routine messages, working/finished updates, and completed requests never become cards. A new prompt opens the compact panel without taking keyboard focus; file editors and active drags keep their current view and show a badge instead. When the final request resolves, its card and badge disappear and the panel closes. Patch review for a live approval can use the larger diff viewer.

In **Settings → Codex**, install the hooks, then review and trust them with `/hooks` in Codex CLI. Existing hooks are preserved and privately backed up. This app update does not alter the hook definitions or require trusting them again.

- Permission requests use the native helper's live, expiring callback. **Allow once** and **Decline** apply to that request only; clearing waits for the helper acknowledgement. Timeout/disconnection hands control back to Codex.
- Desktop questions use a read-only adapter for newly appended local session records. Existing conversations and reasoning are not imported; files are opened without write access. The preview adapter can be disabled separately in Settings. Both session records and the desktop coordination protocol are version-specific and may change; incompatible formats fail without sending.
- Supported desktop questions offer choices, a custom answer, and **Send answer**. The app checks the live chat/question through Codex's local coordination socket, sends a structured reply only after your click, and clears the prompt after Codex records it. Private or unsupported requests use Open in Codex. An unconfirmed send is never automatically retried. Session records can never grant executable permissions.

Pending prompts and drafts stay in memory only. No authentication files are read and nothing is sent to Cloudflare. The hook mailbox uses private same-user files under `Application Support/SortMyMac/CodexInbox`; consumed files are removed. See the [official Codex hook contract](https://learn.chatgpt.com/docs/hooks).

```sh
python3 scripts/verify-codex-bridge.py build/SortMyMac.app/Contents/MacOS/SortMyMacCodexBridge
./scripts/verify-hub.sh --smoke-route codex-question
```

Other isolated routes: `codex`, `codex-approval`, and `codex-diff`.

## Meetings and local transcripts

1. Choose **Record Meeting** on Home. Enter an optional title, choose microphone/system/both, select a microphone, then Start. macOS may request microphone and Screen & System Audio Recording permissions. No screen frames are saved.
2. The collapsed notch keeps a recording indicator and timer. Expand the active meeting for source meters, Pause/Resume, and **Stop & Save**. Closing the panel does not stop recording.
3. Open **Settings → Meetings** to download multilingual Small (recommended, approximately 488 MB) or Base (approximately 148 MB). Downloads are checksum verified; no speech model is bundled or downloaded automatically. Once installed, transcription works offline with Metal acceleration and CPU fallback.
4. Live draft text appears as speech is processed. Timestamped segments are saved incrementally; finalization catches up after recording stops. If a model is missing or fails, the audio remains available for retry.
5. **Meetings** stores a separate record for each meeting, with searchable titles/transcripts, editable text, timestamp seeking, and TXT/Markdown/SRT/VTT exports. Dropped audio/video can also be imported as separate meetings through **Transcribe**. Microphone/system labels are audio-source labels, not speaker identification.

Audio chunks and a manifest are checkpointed approximately every five seconds. An interrupted session recovers completed chunks; an unfinished chunk can be missing. Use **Recover playable audio** in the meeting menu if final assembly was interrupted. Recordings never restart automatically.

For optional summaries, run Ollama yourself and configure its localhost endpoint and an installed model in **Settings → Local AI**. Choose **Generate local summary** on a meeting. Summaries and inferred action items remain separate from editable transcript text. SortMyMac never sends meeting recordings/transcripts to Cloudflare.

The SQLite library is at `~/Library/Application Support/SortMyMac/library.sqlite`. `Meetings/` holds recording chunks/manifests/audio, `Outputs/` holds kept results, `Models/` holds speech models, and `Staging/` holds incomplete transformations; `Cache/Previews/` holds disposable previews and is cleared on restart. Keep these alongside the existing `moves.json` recovery journal. Back up this folder to preserve your library. Saved recordings/results are retained until you remove them.

## Connect Cloudflare

1. Open Settings from the notch or menu bar, then select **Cloudflare**.
2. Enter the 32-character account ID and an API token with **Workers AI Read** permission for that account.
3. Save the token in Keychain and select **Test connection**. This sends a small diagnostic request containing no file data.

Requests use your account's Workers AI access and billing. No service credentials are bundled with the app. Account preferences use UserDefaults; the token uses macOS Keychain. Credentials, file contents, and model responses are not logged.

## Organize files

1. Drag local files toward the notch; the drop target appears only during a drag. Drop, select up to 50 files, then choose **Organize** under the relevant actions or **More**. **File Tools** on Home and **Add files…** also open a native picker.
2. Select **Organize**. Screenshots go together in **Screenshots**, recognized from macOS capture metadata or standard timestamped screenshot filenames. They do not need matching subjects and are excluded from cloud analysis. Remaining files group by topic: limited excerpts are extracted locally from text, Markdown, PDF, and RTF; other images receive small previews. Other formats contribute metadata. Original files stay in place during analysis. Download cloud placeholders in Finder first. Folders, bundles, and symbolic links are excluded.
3. Review the folder cards. Edit a folder's name; right-click a file icon to move it into another group or a new folder. Extra files are accessible from the card's count menu.
4. Drag anywhere on a folder card's background, icon, file count, or previews, or use **Drag All Folders**, into a Finder folder or onto the Desktop. Folder-name fields and extra-file menus keep their normal interactions; right-click a preview for its file actions. Click the drag surface instead to use a native destination picker, including with VoiceOver. The app moves originals only when a destination is accepted. Finder controls icon placement and sorting.

The menu bar also exposes Settings, Recovery, and Quit. Escape closes the panel while preserving work; use the explicit Cancel or Stop controls to stop processing or recording. Escape during a native drag cancels that drag. Hover never activates the app.

The entire notch surface stays pure black, collapsed or expanded, in every macOS appearance. Its contents use dark appearance for readable text and controls while retaining the macOS accent color. Settings and Recovery follow macOS light/dark appearance automatically.

## Privacy and grouping

For files not recognized as screenshots, choosing Organize sends filenames, types, sizes, dates, up to 1,200 characters of extracted text per file, and small image previews to [Cloudflare Clef](https://developers.cloudflare.com/workers-ai/models/clef/). Screenshot-only sessions make no classification requests. The app does not send absolute source paths. Previews are packed into bounded contact sheets with explicit cell coordinates. No data leaves the Mac merely because files were added to the tray.

After local screenshot grouping, Clef scores pairwise topic relationships through typed decisions, in batches of at most 64 questions and four sheets. Complete-link clustering requires every relationship between merged topic groups to score at least 0.8. Unknown or uncertain relationships do not imply a group. Folder names come from shared local keywords and remain editable; unmatched files go into **Other**. A 50-file session compares up to 1,225 relationships over 20 batches; screenshots reduce that work. Renamed captures without macOS capture metadata cannot reliably be recognized locally and follow normal topic grouping.

## Moves, recovery, and Undo

A persistent journal records file identity, source and destination paths, SHA-256 fingerprints, and transfer checkpoints. It lives at `~/Library/Application Support/SortMyMac/moves.json`; it contains metadata, not file contents or credentials. Do not remove this history while moves need recovery.

- Canceled outgoing drags leave source files untouched. Native file promises supply the final destination URL after an accepted drop.
- Same-volume moves use coordinated filesystem moves. Cross-volume transfers verify the copied bytes and unchanged source before source removal. Source removal checks identity and contents again inside file coordination.
- Files are never overwritten. Duplicate basenames receive numbered suffixes. The destination picker numbers existing folder names; native receivers provide their final collision-resolved folder URL. An unexpected existing promise destination is rejected safely.
- **Recovery & Undo…** lists completed and interrupted operations. Undo restores each file to its original path when safe, including after a restart. Partial operations can be undone independently.
- Changed or replaced destinations, occupied original paths, missing parent folders, and ambiguous crash states are preserved for review. Resolve the listed conflict, then retry Undo. Empty destination folders are removed with `rmdir`; folders containing user-added items are kept.

Quit is blocked while a move or recording is active. If macOS or the process is interrupted, reopen Recovery. Network errors and canceled analysis do not move files.

## Development verification

```sh
./scripts/build.sh debug
open -n build/SortMyMac.app --args --smoke-test "/tmp/SortMyMac-QA-$(uuidgen)"
```

Debug-only smoke mode creates disposable text, image, PDF, audio, and transcript fixtures with isolated library/recovery history under a fresh temporary directory. It supplies deterministic test grouping without contacting Cloudflare and keeps the panel open for UI automation. Release builds contain no fixture service. Use its `destination/` folder to test export, cancel, and Undo.

Add `--smoke-appearance light` or `--smoke-appearance dark` to preview either appearance within the debug app, without changing macOS settings. Omit the option to follow the system.

For an isolated app identity that coexists with installed builds:

```sh
./scripts/verify-hub.sh --smoke-route home
# Other routes: crop, images, media, pdf, meetings, models
# Setup/library routes: recording, meeting-list, empty-meetings, permissions, home-error
```

Native engine integration can be checked with `python3 scripts/verify-native.py` after placing the verified Base model in `.build/qa-models/ggml-base.bin`. This check uses upstream's public JFK sample and never opens the microphone.

See [UI practices](docs/UI-Practices.md) and [verification notes](docs/Verification.md).
