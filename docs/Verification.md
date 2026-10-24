# Verification

## Automated checks

Direct reply tests verify chat/question identity, stale/already-answered rejection, private-answer restrictions, marker escaping, partial multi-question resolution, and local socket framing for active/idle threads. Model checks verify one send per explicit action, waiting for recorded acknowledgement, clearing only after confirmation, and refusing blind retries of an unconfirmed send. The local desktop owner-discovery/snapshot path was inspected read-only against the installed client; actual user-click submission is verified separately.

Input-only Codex checks verify that routine messages are ignored, pending questions survive working/finished updates, resolved prompts clear selection/drafts and notify the panel, wrong-thread acknowledgements do not clear a prompt, and pending storage stays bounded. Session-reader tests cover no historical backfill, new sessions, partial lines, oversized/malformed records, file replacement, async accepted-vs-answered semantics, and refusal to turn session records into executable approval callbacks.

The Codex inbox, selectable questions, persistent answer drafts, setup page, and expanded diff viewer were inspected in a separately named packaged UI test app. Approval controls remain fixed below scrolling request details; code lines fill the diff viewer without wrapping into a narrow column. No real Codex hooks were installed, trusted, or used to approve an action during this verification. Actual trusted-hook delivery remains a user setup/acceptance check.

Codex coverage includes expiring and thread-bound approvals, option/description parsing for both question shapes, patch bounds, unrelated-tool filtering, private mailbox symlink rejection, idempotent hook installation/removal, preserved unrelated handlers and backups, malformed configuration protection, bounded inbox history, duplicate events, and helper acknowledgements. The packaged helper fixture script verifies Allow/Decline/handoff/disconnect, wrong-thread rejection, and multi-read bounded input without launching an agent or changing real Codex configuration. Live trusted-hook delivery still requires a compatible Codex client and the user’s trust review.

The current utility build passes 103 tests (84 core and 19 native-app tests). Crop checks cover drawing in both directions, moving without resizing, edge/corner limits, ratio locks, letterboxed coordinates, rotation round trips, and real PNG exports of asymmetric colored fixtures at all four rotations. Preview/export rounding uses integer pixel edges. Permission tests verify passive status reads, denied-microphone recovery, explicit requests, and refreshed/revoked grants using injected APIs without changing real permissions.

Existing organization and native-app regression coverage includes:

- File intake, deduplication, unsupported items, the 50-file limit, source modifications, and replacement with identical size and timestamp.
- Notch geometry across screen origins and display widths, with physical cutout and island layouts.
- Local text, PDF, RTF, and image extraction; bounded image contact sheets and their state references.
- Clef payloads and response schema, authentication failures, malformed answers, bounded retries, cancellation, and batch limits.
- Deterministic complete-link grouping, uncertain relationships, folder naming, reassignment, and file conservation during edits.
- Local screenshot recognition from capture metadata and timestamped filenames, renamed captures, ordinary-image exclusions, a 50-screenshot session with no network requests, and mixed sessions that send only remaining topic files to Clef.
- Real temporary-file moves, numbered collisions including maximum-length filenames, verified copy-before-delete transfer behavior, partial failures, journal corruption, restart recovery, and interrupted Undo.
- Source removal checks inside file coordination, occupied original paths, changed and replaced destinations, and preservation of user-added destination files.
- Native promise pasteboard writing and delegate fulfillment at an explicit destination, plus retired-session rejection without source mutation.
- Folder-card drag geometry across content and padding, pass-through bounds for name fields and overflow menus, and rounded-corner/outside-click handling.

The copy-before-delete tests force the cross-volume branch using real temporary files. A physical removable drive is still useful for release acceptance.

## UI checks performed

On 25 October 2026, a real question was sent to the running release app. The user selected an option and clicked Send answer in the notch; the structured question reply arrived in the originating Codex chat, and the user confirmed that the notch closed. This verifies live desktop question submission and dismissal separately from the isolated UI fixture. Live executable-permission acceptance remains a separate check.

The direct-answer controls were checked in an isolated packaged QA app: Send answer stays disabled until an answer is selected, becomes enabled after selection, and the confirmed reply removes the prompt and collapses the notch without a completed-event card. This UI fixture uses an isolated local acknowledgement; real desktop submission requires a separate human-click check.

The new Permissions settings page was inspected in a separate packaged QA identity. Microphone and screen status, request controls, Files & Folders link, and Refresh fit the grouped Settings layout. Opening the screen/audio privacy link reached the macOS Screen & System Audio Recording pane. No permission toggle or capture request was activated by the agent. Utility routes now use the compact surface; only file and transcript editors use the larger size.

Shelf batch removal was checked with disposable fixtures: deselecting one of four items changed the button to Deselect (3), and Remove cleared those three shelf references while retaining the unselected item. Select all/Deselect updated the count and showed/hid Remove correctly. The SQLite shelf count decreased from seven to four; SHA-256 verification confirmed all seven source files remained unchanged.

Home now uses a fixed native Grid rather than a ScrollView, with no recent-meeting row below the six tools. The packaged `home-error` smoke route verified that both card rows remain visible with an error banner; the accessibility tree has no Home scroll area. Home cards switch to a shorter layout while the banner is shown.

The meeting-library list background is hidden; each row has its own rounded surface, centered icon/details, and status badge. Populated rows were inspected in the packaged app. Recording setup was reduced from the 960 × 720 editor size to the compact 620 × 430 surface, using aligned form rows and a single Cancel/Start action bar. Its shared footer/Home action is omitted. The compact setup was visually checked with all fields and the optional model-setup notice visible; all 78 regression tests pass.

The Meetings empty state now fills the remaining library area below search and centers its icon, title, and bounded, center-aligned description. Its packaged-app layout was checked with the `empty-meetings` smoke route. Searches with no matches use the same centered container.

The shared-control pass was inspected in an isolated packaged app: crop toolbar, meeting library/search, recording setup, audio trim controls, and the compact shelf/action row. Native large buttons/pickers, labeled fields, grouped surfaces, selection checkmarks, and separated action bars were checked at the normal notch sizes. Search typing showed its focus border and Clear restored the placeholder. The recording form fits its expanded route without requesting capture permissions. No real recording or network download was started. All 78 existing tests pass; full keyboard navigation, VoiceOver, and multiple-display acceptance still need a user-device pass.

The Home color pass was inspected in an isolated packaged app using the supplied Reminders screenshot as a visual reference. All six gradient cards fit the compact Home surface, with SF Symbols, readable titles/details, and counts drawn from the library. The black notch surround stays intact; the six destinations retain their existing actions. This is a presentation-only change, verified by compilation and native UI inspection.

The interactive image editor was checked in an isolated packaged QA app with disposable images. Dragging created a 398 × 300 selection; dragging inside preserved that size, and pulling a corner resized it. A 1:1 preset stayed square during resizing and rotation. In the final build, rotating a 398 × 300 crop produced a 300 × 398 encoded preview, and keeping the result saved a separate PNG with those exact dimensions. The large single canvas, compact toolbar, Edit/Result/Compare controls, and image-bounded transparency background were inspected visually. Real user files and audio capture were not used for these checks.

The packaged debug app was opened and inspected through native accessibility and screenshots. Welcome, Cloudflare settings, notch intake, grouped folder cards, completion, and Recovery layouts were checked. The first-launch content installation and fixed sidebar sizing were corrected during this pass.

The appearance pass checked intake and grouped review in light and dark app-local previews, using blue and purple system accent overrides. Dark Settings, folder-name fields, secondary text, native primary buttons, and the custom outgoing drag control were visually checked. These previews did not change macOS preferences. Automatic changes while the app is already running remain a manual acceptance check.

Using four disposable fixtures, grouping produced two folders. The native destination picker moved all four original files into those folders, and Recovery Undo restored all four and removed the empty destination folders. The results were checked on disk as well as in the UI.

Outgoing native drags were started and canceled with Escape; the sources remained intact and no journal was created. The desktop automation session did not complete a cross-window Finder drop, so that gesture remains a manual acceptance item. Native promise delegate fulfillment is covered by an automated integration test. A successful live Clef call was not performed because account credentials were not configured.

During account setup, the live Clef connection diagnostic subsequently passed. The screenshot accuracy fix was checked locally against 53 Desktop images: all 53 were recognized as screenshots using names or capture metadata, without uploading image contents or moving files. The 50-file session limit remains in place.

## Manual acceptance before distribution

1. Connect a real Cloudflare account; test PDF, text, RTF, image, and mixed-format topic grouping. Verify cancellation and offline/authentication errors.
2. Select multiple files in Finder, drag toward the notch, and verify opening and target highlighting. Drop and confirm source locations remain unchanged until export.
3. Drag one folder and then all remaining folders into a Finder window and onto the Desktop. Verify actual contents, source removal, collision names, and Undo.
4. Repeat with existing destination folder names, duplicate source basenames, read-only destinations, a removable volume, and a large file.
5. Change display scaling, attach a monitor, switch Spaces, enter fullscreen, enable Reduce Motion, and exercise VoiceOver and keyboard destination selection. Switch macOS appearance and accent colors while the app is open; include yellow and graphite accents.
6. Interrupt a disposable transfer, reopen Recovery, and verify recovery preserves conflicts rather than overwriting user data.

The release build is ad hoc signed for local use. No Git remote, hosted backend, distribution signing, or notarization is configured.

## Full-card drag and black-notch regression — 25 October 2026

The card's native drag source now observes left-button gestures within its visible padded bounds while SwiftUI retains hit testing. Disposable UI checks verified drags from padding, file counts, and previews; Escape restored the grouped state and left the original files intact. Folder renaming, the extra-file menu, right-click, and Control-click were checked with a seven-file card. Native drag monitors are removed when their representable is dismantled or leaves its window.

App-local light and dark previews showed black intake and grouped surfaces with readable text. The light preview's completed surface and the dark preview's collapsed surface were also black. Recovery retained light appearance in the light preview. Switching macOS appearance while the app remains open is still a manual acceptance check.

The destination picker exported nine disposable files into two folders. Both journal entries completed; Recovery Undo restored all nine originals and removed both empty destination folders. File contents and journal states were verified on disk.

A live Finder file-promise drop in the isolated test app stalled inside `NSFileCoordinator` before any source moved. All disposable originals remained intact; the test process was stopped and only its empty, identity-verified destination was removed. Finder drop completion remains an unresolved acceptance item; this patch retains the existing transfer coordination. Subsequent automated drag checks used a QA-only destination restriction in the temporary build to keep test exports contained.

The current shared checkout passed all 57 tests and a release build. The isolated baseline plus the UI changes also passed all 44 baseline/regression tests before the concurrent utility additions were included.

## Utility hub implementation (25 October 2026)

The expanded implementation adds SQLite-backed shelf/jobs/meetings, contextual file actions, expandable editors, image/PDF/media processors, recoverable batch renames, bounded ZIP extraction, exact-duplicate review, destinations, presets/Shortcuts, local meeting capture/transcription, local Ollama summaries, and WebP encoding. The existing move journal remains separate and compatible.

Automated verification now includes 62 core tests and 9 native-app tests. Added checks cover:

- Local screenshot grouping with empty Cloudflare credentials; compatible action subsets and ordering.
- Library persistence across connections and independent saved meetings; shelf identity and replaced sources.
- Image dimensions, source preservation, impossible target sizes, cancellation, and staged publication.
- PDF page ordering/rotation, annotation preservation, page splitting, and selectable text in generated PDFs.
- ZIP round trips, byte limits, traversal rejection, and streamed checksum validation.
- Rename recovery with an occupied original path; destination-copy collision numbering.
- Preset chains, output type/dimensions, and intermediate-output cleanup.
- Audio trim duration, portrait video trim/orientation, missing audio tracks, GIF frame counts, and source-offset assembly.
- Recording checkpoint files, pause/resume offsets, playable CAF chunks, and restart recovery from the durable manifest.
- Kept previews surviving cache invalidation and library reopening; navigation independent from organization.

The native bridge was also exercised with the checksum-verified multilingual Base model and upstream whisper.cpp's public `samples/jfk.wav`. Both direct native inference and the complete packaged Swift import → normalization → transcription → saved meeting flow produced the expected speech transcript offline. WebP encoding was checked through the bundled library. No microphone or private meeting audio was used for this verification.

Packaged UI checks used `scripts/verify-hub.sh` with a separate application identity and isolated temporary library. Home shows utility options without a drop area. The audio editor displayed a waveform, range handles, numeric fields, loop/mute/frame controls, and an encoded preview. Selecting 12–26 seconds produced a 14-second output with its actual file size and Keep/Save actions. The meeting library/detail displayed the finalized public-sample transcript with editable text, a timestamp button, playback, and export controls. The image editor was also checked with original/result comparison and an encoded JPEG preview after resizing from 800 to 400 pixels. Editors and the pure-black notch were visually inspected through the native accessibility tree and screenshots.

Remaining hardware acceptance: microphone/system/both capture through actual macOS permissions, Bluetooth/hotplug behavior, a real meeting app, an hour-long recording, sleep/disk-full interruptions, and multi-display/fullscreen behavior on physical displays. These require a real session; automated checkpoint and media tests do not establish that hardware acceptance. Ollama summaries require a locally running user-configured server/model and were not exercised against a live server. No Cloudflare upload was performed during utility verification.
