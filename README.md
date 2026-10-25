# BetterNotch

A native macOS notch hub for file tools, visual previews, meeting recording, offline transcripts, and Codex questions and permissions. Hover to open your tools; drag files toward the notch to choose an action.

Built with SwiftUI and AppKit for **macOS 14 or later**. On Macs without a camera notch, BetterNotch appears as a small island at the top of the display.

## Features at a glance

| Area | Available features |
| --- | --- |
| Notch hub | Six colorful Home tiles, drag-only drop target, compact utility pages, larger editors, keyboard access, and recording/job indicators |
| Shelf | Persistent file references, multiselect/removal, Quick Look, drag-out, Finder reveal, missing-file location, and pinned destinations |
| Images | Interactive drag crop, resize, rotation, JPEG/PNG/HEIC/TIFF/WebP conversion, compression, background removal, OCR, and result comparison |
| Audio & video | Timeline previews, waveform/thumbnail scrubbing, start/end trim handles, selection looping, native conversion, video compression, audio extraction, and short GIFs |
| PDFs & documents | Merge, reorder/extract/rotate/split pages, scanned-page OCR, text extraction, image-based compression, and PDF creation |
| File management | Screenshot-aware organization, rename previews with Undo, ZIP creation/extraction, exact duplicate review, and explicit Copy/Move destinations |
| Meetings | Microphone/system/both audio capture, source selection and meters, pause/resume, five-second checkpoints, and interrupted-recording recovery |
| Transcripts | Local Whisper models, live drafts, saved meeting search, editable timestamped transcripts, playback seeking, and TXT/Markdown/SRT/VTT export |
| Codex | Pending questions and permission requests, selectable/custom answers, direct Send answer, Allow once/Decline, diff review, and automatic dismissal after confirmation |
| Automation & AI | Reusable action chains, configured macOS Shortcuts, and optional local Ollama summaries for meetings and extracted text |
| Safety & settings | New-file transformations, staged outputs, cancellation/retry, move recovery, collision protection, permission controls, and Keychain-backed cloud credentials |

[Build and run](#build-and-run) · [File tools](#notch-shelf-and-file-actions) · [Codex](#codex-in-the-notch) · [Meetings](#meetings-and-local-transcripts) · [Privacy](#privacy-and-grouping) · [Verification](docs/Verification.md)

## Build and run

Requires macOS 14 or later, Xcode with Swift 6, Git, and Python 3. The first build fetches pinned ZIPFoundation, whisper.cpp, and libwebp sources. If CMake is absent, it installs a pinned copy in `.build/native/tooling`; it does not change your system Python or require Homebrew. Native engines are bundled in the app.

```sh
git clone https://github.com/sreeragh-s/betternotch.git
cd betternotch
./scripts/build.sh
open build/BetterNotch.app
swift test
```

The build script produces an ad hoc signed local app with its own generated icon and the bundle identifier `com.betternotch.native`. Distribution outside this Mac requires Developer ID signing and notarization. A packaged installer is not currently provided.

File tools and recording work without a cloud account. Transcription needs a one-time speech-model download. Cloudflare topic grouping and optional Ollama summaries have separate setup below.

### Upgrading an existing installation

BetterNotch imports existing app settings once, keeps existing saved-library and recovery paths valid, and can read the previous Keychain token. Existing trusted Codex hooks remain recognized; the rename does not edit your hook configuration. New installations use the BetterNotch data directory and hook names. Run one version at a time when sharing an existing library. macOS may require granting microphone and screen/system-audio access to the renamed app in **Settings → Permissions**.

## Notch, shelf, and file actions

Hover opens Home with Record Meeting, Meetings, Organize, Shelf, Recent Results, and Activity. Dragging files temporarily shows two distinct targets: **Shelf** parks references and opens file tools; **Organize** moves originals temporarily into its own durable staging area and starts grouping. Drop on the chosen target; hovering or canceling an incoming drag never moves files. The regular shelf remains separate.

The shelf and recent results survive restarts. Drag any file tile into a Finder folder, onto the Desktop, or into an app that accepts files to copy it there. Select several files, then drag a selected tile to copy the visible selection together; dragging an unselected tile copies just that file. Copies keep the originals and shelf references in place. Right-click a file to preview, open, reveal in Finder, save a copy, copy to the clipboard, or remove its shelf reference. Missing/replaced files have Locate and Remove actions. Removing a reference never deletes the source; managed results have a separate Move to Trash command. Pin folders under Destinations for explicit Copy or Move operations.

Settings → Permissions shows microphone and screen/system audio access, offers explicit permission requests, and opens the relevant macOS privacy panes. Files & Folders settings are linked separately. Status refreshes when you return to the app; opening this page never starts recording or requests access automatically.

- **Images:** resize, convert (JPEG/PNG/HEIC/TIFF/WebP where available), compress with a target size, crop/rotate, remove background, and OCR. Drag directly on the image to crop; move the selection or resize its edges/corners, with optional ratio locks and rotation. The editor starts with one large canvas; encoded results add Result/Compare views with zoom. Format/quality and presets live in compact menus. JPEG requires a white/black transparency background.
- **Audio/video:** scrub a waveform or thumbnail timeline; set and loop one start/end interval; trim, convert, compress video, extract audio, or make a GIF (20 seconds maximum). Generate an encoded preview for actual file size and playback, then Keep results or Save. Audio outputs are M4A/WAV/AIFF; native video outputs are MP4/MOV.
- **PDF/documents:** merge with file ordering, extract/reorder/rotate pages, split into one PDF per page, OCR scanned pages, and create PDFs from text/RTF/images. Image-based PDF compression explicitly flattens text and annotations; ordinary page operations preserve them.
- **File management:** preview batch renames and undo them in Activity; create/preview/extract ZIPs; review exact duplicates without automatic deletion.
- **Presets:** save settings from an editor, then append transformation steps from another editor to build a chain. The chain validates every step and uses the same preview/export path. Configure a macOS Shortcut in Settings → Local AI to expose custom file actions, including Office conversions.

Shelf transformations create new files. Organize explicitly moves originals into temporary managed storage and provides Undo. Transformation outputs are staged and validated before publication; expensive jobs queued during a recording wait until recording/transcription yields. Activity exposes real per-file progress, cancellation, results, retries, and interrupted jobs.

## Codex in the notch

The notch shows **only pending questions and permission requests**. Routine messages, working/finished updates, and completed requests never become cards. A new prompt opens the compact panel without taking keyboard focus; file editors and active drags keep their current view and show a badge instead. When the final request resolves, its card and badge disappear and the panel closes. Patch review for a live approval can use the larger diff viewer.

In **Settings → Codex**, install the hooks, then review and trust them with `/hooks` in Codex CLI. Existing hooks are preserved and privately backed up. This app update does not alter the hook definitions or require trusting them again.

- Permission requests use the native helper's live, expiring callback. **Allow once** and **Decline** apply to that request only; clearing waits for the helper acknowledgement. Timeout/disconnection hands control back to Codex.
- Desktop questions use a read-only adapter for newly appended local session records. Existing conversations and reasoning are not imported; files are opened without write access. The preview adapter can be disabled separately in Settings. Both session records and the desktop coordination protocol are version-specific and may change; incompatible formats fail without sending.
- Supported desktop questions offer choices, a custom answer, and **Send answer**. The app checks the live chat/question through Codex's local coordination socket, sends a structured reply only after your click, and clears the prompt after Codex records it. Private or unsupported requests use Open in Codex. An unconfirmed send is never automatically retried. Session records can never grant executable permissions.

Pending prompts and drafts stay in memory only. No authentication files are read and nothing is sent to Cloudflare. The hook mailbox uses private same-user files in the active library's `CodexInbox/` directory; consumed files are removed. See the [official Codex hook contract](https://learn.chatgpt.com/docs/hooks).

```sh
python3 scripts/verify-codex-bridge.py build/BetterNotch.app/Contents/MacOS/BetterNotchCodexBridge
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

For optional summaries, run Ollama yourself and configure its localhost endpoint and an installed model in **Settings → Local AI**. Choose **Generate local summary** on a meeting. Summaries and inferred action items remain separate from editable transcript text. BetterNotch never sends meeting recordings/transcripts to Cloudflare.

New installations store the SQLite library at `~/Library/Application Support/BetterNotch/library.sqlite`; upgrades continue using their existing library directory to preserve saved absolute file references. `Meetings/` holds recording chunks/manifests/audio, `Outputs/` holds kept results, `Models/` holds speech models, and `Staging/` holds incomplete transformations; `Cache/Previews/` holds disposable previews and is cleared on restart. Keep these alongside the existing `moves.json` recovery journal. Back up this folder to preserve your library. Saved recordings/results are retained until you remove them.

## Connect Cloudflare

1. Open Settings from the notch or menu bar, then select **Cloudflare**.
2. Enter the 32-character account ID and an API token with **Workers AI Read** permission for that account.
3. Save the token in Keychain and select **Test connection**. This sends a small diagnostic request containing no file data.

Requests use your account's Workers AI access and billing. No service credentials are bundled with the app. Account preferences use UserDefaults; the token uses macOS Keychain. Credentials, file contents, and model responses are not logged.

## Organize files

1. Drag up to 50 local files toward the notch and drop directly on **Organize**. The files move out of their source folders into durable, private Organize storage, then grouping starts. The shelf is unchanged. **Home → Organize → Choose files…** and the menu bar's **Organize files…** are picker alternatives with the same move behavior. Invalid/over-limit batches are rejected before moving anything. A failed or canceled intake rolls completed moves back; any conflict remains listed in Recovery. **Add files…** belongs to the separate reference-only shelf flow.
2. Screenshots go together in **Screenshots**, recognized from capture metadata or timestamped filenames. They are excluded from cloud analysis. Other files group by topic using locally extracted excerpts/previews and your Cloudflare account. Files stay in Organize while grouping; **Undo** cancels grouping and restores their original locations. Download cloud placeholders in Finder first. Folders, bundles, and symbolic links are excluded.
3. Review the folder cards. Edit a folder's name; right-click a file icon to move it into another group or a new folder. Extra files are accessible from the card's count menu.
4. Drag a folder card or **Drag folders to Finder** into any Finder folder or onto the Desktop. This moves the held files to that destination, including a different disk after copy verification. Canceling the outgoing drag leaves them safely in Organize for another attempt or Undo. Click the drag surface for a native destination picker with the same behavior. Existing folders/files are numbered rather than overwritten. Folder-name fields and extra-file menus retain their normal interactions.
5. **Undo** on the organization page returns the entire session to its original locations, including folders already moved out and files still held in Organize. It remains available after completion and after restart through **Settings → Recovery**. Changed files and occupied original paths are preserved for review. Finish or Undo the current session before moving in another batch.

The menu bar also exposes Settings, Recovery, and Quit. Escape closes the panel while preserving work; use the explicit Cancel or Stop controls to stop processing or recording. Escape during a native drag cancels that drag. Hover never activates the app.

The entire notch surface stays pure black, collapsed or expanded, in every macOS appearance. Its contents use dark appearance for readable text and controls while retaining the macOS accent color. Settings and Recovery follow macOS light/dark appearance automatically.

## Privacy and grouping

For files not recognized as screenshots, choosing Organize sends filenames, types, sizes, dates, up to 1,200 characters of extracted text per file, and small image previews to [Cloudflare Clef](https://developers.cloudflare.com/workers-ai/models/clef/). Screenshot-only sessions make no classification requests. The app does not send absolute source paths. Previews are packed into bounded contact sheets with explicit cell coordinates. Adding references to the regular Shelf never starts cloud grouping.

After local screenshot grouping, Clef scores pairwise topic relationships through typed decisions, in batches of at most 64 questions and four sheets. Complete-link clustering requires every relationship between merged topic groups to score at least 0.8. Unknown or uncertain relationships do not imply a group. Folder names come from shared local keywords and remain editable; unmatched files go into **Other**. A 50-file session compares up to 1,225 relationships over 20 batches; screenshots reduce that work. Renamed captures without macOS capture metadata cannot reliably be recognized locally and follow normal topic grouping.

## Moves, recovery, and Undo

Organize stores session manifests in `Organization/Sessions/`, held originals in `Organization/Items/`, and a transfer journal at `Organization/transfers.json` in the active library directory. These are durable user data, outside disposable preview caches. Do not remove them while files are staged or Undo is needed. Legacy and explicit shelf moves keep their history in `moves.json`.

- Canceled incoming drags leave sources untouched. Canceled outgoing drags leave held files in Organize. Native file promises supply the accepted destination URL.
- Same-volume moves use coordinated filesystem moves. Cross-volume transfers verify the copied bytes and unchanged source before source removal. Source removal checks identity and contents again inside file coordination.
- Files are never overwritten. Duplicate basenames receive numbered suffixes. The destination picker numbers existing folder names; native receivers provide their final collision-resolved folder URL. An unexpected existing promise destination is rejected safely.
- **Recovery & Undo…** lists organization sessions and earlier move/copy history. Organization Undo reverses outbound moves first, then restores staged originals, including across volumes and after a restart. Earlier copy records retain their copy-specific Undo behavior.
- Changed or replaced destinations, occupied original paths, missing parent folders, and ambiguous crash states are preserved for review. Resolve the listed conflict, then retry Undo. Empty destination folders are removed with `rmdir`; folders containing user-added items are kept.

Quit is blocked during file intake, a move, or recording. Quitting with files parked in Organize is safe: the session reappears after restart, with Undo available. Interrupted transfers are marked for review. A grouping/network error retains staged files for Retry or Undo.

Transfer journals write version 2, and organization manifests use version 1. Existing version-1 move history remains readable; older app builds cannot read version-2 transfer history. Shelf destination actions explicitly labeled Move continue to move originals regardless of location.

## Current limits

- Organization accepts up to 50 files per session. Other tools validate their supported input types separately.
- Media trim keeps one contiguous interval per file. GIF creation is limited to 20 seconds; codec support follows the native macOS exporters.
- Meetings start manually. Calendar integration, meeting bots, automatic recording, and identification of individual speakers are not included.
- Speech models require an initial download. Ollama is optional and must be installed and configured separately.
- Office-document conversion requires a configured macOS Shortcut. Ordinary PDF page operations and image-based compression have different preservation behavior, described above.
- Codex integration depends on compatible local hooks and desktop session/coordination formats. Private or unsupported questions hand off to Codex; uncertain sends are never retried automatically.

## Development verification

```sh
./scripts/build.sh debug
open -n build/BetterNotch.app --args --smoke-test "/tmp/BetterNotch-QA-$(uuidgen)"
```

Debug-only smoke mode creates disposable text, image, PDF, audio, and transcript fixtures with isolated library/recovery history under a fresh temporary directory. It supplies deterministic test grouping without contacting Cloudflare and keeps the panel open for UI automation. Release builds contain no fixture service. Use its `destination/` folder to test export, cancel, and Undo.

Add `--smoke-appearance light` or `--smoke-appearance dark` to preview either appearance within the debug app, without changing macOS settings. Omit the option to follow the system.

For an isolated app identity that coexists with installed builds:

```sh
./scripts/verify-hub.sh --smoke-route home
# Other routes: crop, images, media, pdf, meetings, models
# Setup/library routes: recording, meeting-list, empty-meetings, permissions, home-error
# Drag/organization routes: drop, drop-organize, organize
# Organization layout states: empty-organize, organize-completed
# Native promise acceptance fixture: native-promise (disposable sources and destination)
```

Native engine integration can be checked with `python3 scripts/verify-native.py` after placing the verified Base model in `.build/qa-models/ggml-base.bin`. This check uses upstream's public JFK sample and never opens the microphone.

See [UI practices](docs/UI-Practices.md) and [verification notes](docs/Verification.md).
