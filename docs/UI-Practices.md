# BetterNotch UI specification

## Surface and geometry

- AppKit owns window placement, drag sessions, first-click handling, and the menu bar. SwiftUI owns content and transitions.
- A transparent, borderless, nonactivating panel keeps the notch's outer surface pure black, collapsed or expanded, in both system appearances. Colored utility cards sit within that surface. Read safe-area and auxiliary menu-bar geometry from NSScreen; never infer hardware geometry from a model name.
- Use a top-center island on displays without a cutout. Recompute frames on display changes and wake. Leave shadow padding outside the visible surface.
- Upper corners flare outward with a concave curve; lower corners are continuously rounded. A faint semantic outline and two shadow layers separate the expanded surface from light wallpaper.
- Keep controls below the camera cutout and menu bar; empty transparent margins do not intercept clicks.

## Layout and interaction

- `HubComponents.swift` owns the shared notch primitives and a 4/8/12/16/24-point spacing scale. Use 8 points between controls, 12 between related groups, 16 inside panels, and 24 for form/popover insets. The shell retains its 32-point side clearance.
- Use native large macOS bordered buttons, menu pickers, rounded text fields, checkboxes, sliders, and segmented controls. Native controls retain disabled, keyboard, focus, and accessibility behavior. Keep one prominent action in each action bar and secondary actions neutral; use segments for only a few mutually exclusive choices.
- Use 13-point body text, 11-point supporting labels, and 20-point page titles. Keep form labels visible above controls or aligned in a form column, group related options in subtle bordered panels, and separate bottom action bars with a divider. Recording setup and the meeting library use the compact 620 × 430 surface, clamped to the display; scroll content as needed. Full transcript and file editors can expand.
- Recording setup has Cancel and Start recording in one action bar. Omit the shared footer and its redundant Home button on this route. The meeting library also omits the footer Home button, using the header navigation. Meeting rows have individually bounded backgrounds, vertically centered icons/details, and concise status badges; keep the list's unused area transparent.
- Icon controls have approximately 32-point targets and accessible names. Search has a visible focus border and a Clear control. Selected shelf items use a checkmark, accent fill, and border; selection is also exposed to accessibility. Action menus use their intrinsic width, while form selects fill their field column.
- Shelf selection uses Deselect (count) with an adjacent Remove action whenever visible items are selected. Deselect clears that selection; Remove discards only the selected references and preserves source files. With no selection, show Select all and hide Remove.
- The full shelf tile starts a native copy drag with one file URL per item. Dragging a selected tile includes only the visible selection; an unselected tile drags alone. Preserve click selection, keyboard actions, context menus, scrolling, and originals. Resolve bookmarks at gesture start and reject a batch with missing/replaced files rather than silently omitting them. Keep the panel open until the outgoing session ends or is canceled.
- Toolbars wrap when needed. Preserve room for previews and use a restrained press response that respects Reduce Motion. Audio-only media disables video frame-step controls.

- System typography, SF Symbols, native Finder file icons, one-line truncated filenames, full-name tooltips, monospaced progress counts, and the macOS accent color.
- Keep dark appearance scoped to the notch panel and its SwiftUI contents so text and controls remain readable on black. Settings and Recovery follow system appearance. Retain automatic macOS accent changes, primary and secondary text, native button styling, and subtle accent fills.
- Compact controls use circular hover backgrounds and a slight spring compression on press. Click targets remain comfortably larger than their symbols.
- Home uses Reminders-inspired colored cards: coral recording, blue meetings, orange organization, purple shelf/file tools, green results, and slate activity. Use subtle diagonal gradients, clear SF Symbols, bold titles, and real counts at the upper right. Maintain readable text and a solid-color treatment for Increase Contrast; color never replaces labels.
- Home is a fixed two-row grid with no scrolling or meeting previews beneath it. Meetings live in their library; Activity opens pending organization when present. Use shorter cards while an error banner is visible so all six tools remain available.
- Ordinary hover shows Home and available utilities. A valid external file drag reveals separate Shelf and Organize cards; only the card under the pointer accepts the drop. Shelf parks references and exposes tools. Organize moves originals into its own durable staging area before grouping, without touching shelf references or selection. The shelf registry does not include organization. Disable its target while busy, over 50 files, or holding an unfinished session. Validate the whole batch before moving. Canceling an incoming drag restores the current route/expansion without moving files. Internal outgoing drags never switch to intake.
- Compact Home/actions and expanded editors share the notch surface. Large editors stay below the cutout, fit the current display, and preserve draft settings across navigation. Preview and export use the same immutable settings snapshot.
- All utility routes, including speech models and Activity, use the same compact notch size. Only file editors and the meeting transcript editor use the expanded editor size. Utility content scrolls inside the fixed surface when necessary; Home remains a fixed grid.
- A native multi-file open panel complements Finder drag and drop. Context menus expose secondary actions; primary actions stay visible.
- One AppKit drop destination resolves incoming files. Native file promises resolve outgoing folder destinations asynchronously.
- Each folder card's full padded surface starts native outgoing drags, including the icon, file count, previews, and empty space. Name fields and overflow menu buttons pass through to their existing controls; right-click and Control-click reach the preview context menus. Click the drag surface for a destination picker.
- Organized folders always move from staging to the accepted Finder destination, including other volumes after verification. Canceled outgoing drags leave staged files available. Write promised folders directly to the receiver's URL and complete once; never acquire another destination file-coordination claim while Finder is awaiting the promise. Transfers still coordinate private sources, reserve outputs exclusively, and journal intent before moves. No semaphore may bridge the provider and transfer actor. Number collisions, never overwrite. The picker uses the same move behavior.
- Organize owns the page below the header. Omit the shared footer and Home button. Empty/completed states center a bounded icon/title/description/action group. Populated sessions use a flexible folder grid and one action bar with direct Undo. Undo cancels grouping and reverses the whole intake/export session to original paths; do not silently clear staged files. It remains available after completion and restart. Show intake progress and explicit cancellation/rollback. Group names and partitions persist. Pending sessions must be resumed or undone before replacing them.
- Organization manifests and their transfer IDs are persisted before moving bytes, outside cache directories. Interrupted sessions appear in Recovery. Undo verifies provenance when cross-volume restoration changes identity, never overwrites occupied original paths, and preserves modified outputs for review. Earlier copy records retain their copy-specific Undo behavior.
- The menu bar exposes opening, choosing files, settings, recovery, and quit. Hover never activates the app; intentional keyboard editing may make the panel key.

## Motion and lifecycle

- Grow one persistent surface from its top center using a roughly 300 ms damped spring. Resize the transparent host window before animating its visible surface.
- Reveal content after the surface begins opening; remove it before shrinking. Release key focus and shrink the host frame after collapse completes.
- Use cancellable hover delays and exit hysteresis. A drag or open context menu keeps the panel available. No continuous idle animation or cursor polling.
- File gathering reflects actual group membership. Do not animate invented classification progress. Reduce Motion replaces travel and bounce with fades.
- Optional haptics use the public AppKit API. Use accessible names, status announcements, keyboard commands, and semantic colors.
- Clean up event monitors, observers, asynchronous tasks, and window content when their owners disappear. Background work must not depend on a settings view remaining alive.

## Setup and settings

- Native sidebar navigation, grouped forms, fixed readable sidebar width, standard title bar, secondary explanatory text, and inline actionable errors.
- Permissions is a Settings sidebar page with live microphone/screen access, explicit request buttons, and direct privacy-pane links. Refresh on app/window activation, and never request access or start capture merely by displaying Settings. Files & Folders is managed in macOS; do not invent a global granted/denied state for individual folder access.
- A short first-launch walkthrough explains intake, grouping, outgoing moves, and cloud data disclosure. Settings owns display, hover, haptics, account ID, and Keychain-backed token controls.
- Credential state, network failures, partial moves, and undo conflicts use precise status copy. Destructive file operations are never implied by a decorative animation.

## Image tools

- Start with one large canvas and a compact toolbar. Show Edit/Result/Compare only after an encoded result exists. Keep export settings in a popover and presets in More.
- Crop on the image: drag a new selection, move inside it, or pull a corner/edge handle. Use visible handles with generous hit targets, a thirds grid, dimmed excluded pixels, ratio presets, rotation, and Reset.
- Use one pixel-aligned selection model for displayed crops and exports, including rotation. Show output dimensions and actual encoded size. Preserve the source and create a new result.
- Keep transparency checkerboards within image bounds and show crop instructions only while editing.

## Product boundary

Codex shows only pending questions and permissions, grouped by chat. Do not create cards for routine messages or working/finished updates. Resolved prompts, drafts, and badges are removed; close the panel when no input remains. New requests can open the compact panel without taking focus or interrupting a file editor/drag. Approval controls wait for the live helper acknowledgement. Question answers require an explicit Send answer action and clear only after Codex records the reply. Disable duplicate sends while waiting; an unconfirmed delivery requires checking Codex before retrying. Open in Codex remains available for private/unsupported questions. Session records are read-only previews and can never authorize an action. Setup guidance stays in Settings.

The application includes file organization, local file transformations and previews, a persistent shelf, meeting audio recording, and local meeting transcripts/summaries. Recording is always started explicitly. Transformations preserve source files; moving and renaming originals use explicit actions and recovery history. All implementation, branding, assets, and documentation are original to BetterNotch.
