# SortMyMac UI specification

## Surface and geometry

- AppKit owns window placement, drag sessions, first-click handling, and the menu bar. SwiftUI owns content and transitions.
- A transparent, borderless, nonactivating panel blends a pure black surface into the physical camera cutout. Read safe-area and auxiliary menu-bar geometry from NSScreen; never infer hardware geometry from a model name.
- Use a top-center island on displays without a cutout. Recompute frames on display changes and wake. Leave shadow padding outside the visible surface.
- Upper corners flare outward with a concave curve; lower corners are continuously rounded. A faint white outline and two shadow layers separate the expanded surface from light wallpaper.
- Keep controls below the camera cutout and menu bar; empty transparent margins do not intercept clicks.

## Layout and interaction

- System typography, SF Symbols, native Finder file icons, one-line truncated filenames, full-name tooltips, monospaced progress counts, and a restrained mint accent.
- Compact controls use circular hover backgrounds and a slight spring compression on press. Click targets remain comfortably larger than their symbols.
- The empty tray is a rounded dashed target. Drag targeting increases border, fill, and label contrast. Loaded files form a horizontal tray; results become folder cards.
- A native multi-file open panel complements Finder drag and drop. Context menus expose secondary actions; primary actions stay visible.
- One AppKit drop destination resolves incoming files. Native file promises resolve outgoing folder destinations asynchronously.
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
- A short first-launch walkthrough explains intake, grouping, outgoing moves, and cloud data disclosure. Settings owns display, hover, haptics, account ID, and Keychain-backed token controls.
- Credential state, network failures, partial moves, and undo conflicts use precise status copy. Destructive file operations are never implied by a decorative animation.

## Product boundary

Only file organization belongs in this application. All implementation, branding, assets, and documentation are original to SortMyMac.
