# Verification

## Automated checks

`swift test` passes 41 tests across the core and native-app test targets. Coverage includes:

- File intake, deduplication, unsupported items, the 50-file limit, source modifications, and replacement with identical size and timestamp.
- Notch geometry across screen origins and display widths, with physical cutout and island layouts.
- Local text, PDF, RTF, and image extraction; bounded image contact sheets and their state references.
- Clef payloads and response schema, authentication failures, malformed answers, bounded retries, cancellation, and batch limits.
- Deterministic complete-link grouping, uncertain relationships, folder naming, reassignment, and file conservation during edits.
- Local screenshot recognition from capture metadata and timestamped filenames, renamed captures, ordinary-image exclusions, a 50-screenshot session with no network requests, and mixed sessions that send only remaining topic files to Clef.
- Real temporary-file moves, numbered collisions including maximum-length filenames, verified copy-before-delete transfer behavior, partial failures, journal corruption, restart recovery, and interrupted Undo.
- Source removal checks inside file coordination, occupied original paths, changed and replaced destinations, and preservation of user-added destination files.
- Native promise pasteboard writing and delegate fulfillment at an explicit destination, plus retired-session rejection without source mutation.

The copy-before-delete tests force the cross-volume branch using real temporary files. A physical removable drive is still useful for release acceptance.

## UI checks performed

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
