import AppKit
import Combine
import BetterNotchCore
import SwiftUI

@MainActor
final class NotchPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

@MainActor
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var receiveFiles: (([URL], FileDropDestination) -> Bool)?
    var dragEntered: ((Int) -> Void)?
    var hoverDestination: ((CGPoint) -> FileDropDestination?)?
    var dragFinished: ((Bool) -> Void)?
    private var validFileDrag = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Local shelf/organized-folder drags must remain outgoing drags.
        guard sender.draggingSource == nil else { return [] }
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return [] }
        validFileDrag = true
        dragEntered?(urls.count)
        _ = destination(sender)
        return .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        validFileDrag && destination(sender) != nil ? .copy : []
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { finishDrag(accepted: false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { finishDrag(accepted: false) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { validFileDrag && destination(sender) != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard validFileDrag, let choice = destination(sender) else { finishDrag(accepted: false); return false }
        let urls = fileURLs(sender)
        let accepted = !urls.isEmpty && receiveFiles?(urls, choice) == true
        finishDrag(accepted: accepted)
        return accepted
    }
    private func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    private func destination(_ sender: any NSDraggingInfo) -> FileDropDestination? {
        let local = convert(sender.draggingLocation, from: nil)
        return hoverDestination?(CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y))
    }
    private func finishDrag(accepted: Bool) {
        guard validFileDrag else { return }
        validFileDrag = false
        dragFinished?(accepted)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Shadow margins should never catch a click intended for the application below.
        if bounds.height > 100 && (point.x < 28 || point.x > bounds.width - 28 || point.y < 28) { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class NotchController {
    #if DEBUG
    private var nativePromiseTestWindow: NSWindow?
    #endif
    private let model: AppModel
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var opening: DispatchWorkItem?
    private var closing: DispatchWorkItem?
    private var reveal: DispatchWorkItem?
    private var expandedBeforeDrag: Bool?
    private var geometry: NotchGeometry { model.geometry }

    init(model: AppModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        // Only the notch stays dark; Settings and Recovery retain the system appearance.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NotchHostingView(rootView: NotchView(model: model))
        host.receiveFiles = { [weak self, weak model] urls, destination in
            guard let self, let model else { return false }
            model.dropTargeted = false
            let accepted = model.acceptDrop(urls, to: destination)
            if accepted { self.expand(immediate: true) }
            return accepted
        }
        host.dragEntered = { [weak self, weak model] count in
            guard let self, let model else { return }
            self.expandedBeforeDrag = self.expandedBeforeDrag ?? model.expanded
            model.dragFileCount = count; model.dropChoice = nil; model.dropTargeted = true
            self.resizeForContent()
            self.expand(immediate: true)
        }
        host.hoverDestination = { [weak model] point in
            guard let model else { return nil }
            let choice = model.dropDestination(at: point)
            if model.dropChoice != choice { model.dropChoice = choice }
            return choice
        }
        host.dragFinished = { [weak self, weak model] accepted in
            guard let self, let model else { return }
            let restoreCollapsed = self.expandedBeforeDrag == false
            self.expandedBeforeDrag = nil
            model.dropTargeted = false; model.dropChoice = nil; model.dragFileCount = 0
            self.resizeForContent()
            if !accepted && restoreCollapsed { self.collapse(force: true) }
        }
        panel.contentView = host
        panel.dismiss = { [weak self] in
            self?.collapse(force: true)
        }
        model.$status.removeDuplicates().debounce(for: .milliseconds(700), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self, self.model.expanded else { return }
                NSAccessibility.post(element: self.panel, notification: .announcementRequested,
                                     userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }.store(in: &subscriptions)
        rebuild()
        model.settings.$displayID.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }.store(in: &subscriptions)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.rebuild() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.rebuild() } })
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown], handler: {
            [weak self] event in
            MainActor.assumeIsolated { self?.track(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown], handler: {
            [weak self] event in
            self?.track(event)
            return event
        }) { monitors.append(local) }
    }

    func rebuild() {
        let selected = NSScreen.screens.first { Self.identifier($0) == model.settings.displayID }
        guard let screen = selected ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else {
            panel.orderOut(nil); return
        }
        opening?.cancel(); closing?.cancel(); reveal?.cancel()
        if model.expanded { model.contentVisible = true }
        model.geometry = NotchGeometry(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                                       leftWidth: screen.auxiliaryTopLeftArea?.width,
                                       rightWidth: screen.auxiliaryTopRightArea?.width,
                                       editor: model.hub.route.isLarge && !model.dropTargeted,
                                       availableHeight: screen.frame.maxY - screen.visibleFrame.minY,
                                       activity: model.hub.isRecording || !model.hub.currentJobs.isEmpty || model.isBusy || model.hub.codex.attentionCount > 0)
        panel.setFrame(model.expanded ? geometry.expandedFrame : geometry.restingFrame, display: true)
        panel.orderFrontRegardless()
    }

    func resizeForContent() {
        rebuild()
    }

    static func identifier(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
    }

    private func track(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        if event.type == .mouseMoved && !model.dropTargeted { expandedBeforeDrag = nil }
        if model.expanded {
            let body = CGRect(x: geometry.screen.midX - geometry.expandedSize.width / 2,
                              y: geometry.screen.maxY - geometry.expandedSize.height,
                              width: geometry.expandedSize.width, height: geometry.expandedSize.height)
            if body.insetBy(dx: -12, dy: -12).contains(point) {
                closing?.cancel(); closing = nil
            } else if event.type == .leftMouseDown {
                collapse()
            } else if closing == nil {
                let work = DispatchWorkItem { [weak self] in self?.collapse() }
                closing = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
            }
        } else if geometry.activationFrame.contains(point) {
            if event.type == .leftMouseDragged && expandedBeforeDrag == nil { expandedBeforeDrag = false }
            expand(immediate: event.type == .leftMouseDragged)
        } else { opening?.cancel(); opening = nil }
    }

    func expand(immediate: Bool = false, keyboard: Bool = false) {
        closing?.cancel(); closing = nil
        guard !model.expanded else { if keyboard { panel.makeKey() }; return }
        if !immediate {
            if model.hub.route != .home { model.hub.route = .home }
            guard opening == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.opening = nil
                self?.expand(immediate: true)
            }
            opening = work
            DispatchQueue.main.asyncAfter(deadline: .now() + model.settings.hoverDelay, execute: work)
            return
        }
        opening?.cancel(); opening = nil
        panel.level = .popUpMenu
        panel.setFrame(geometry.expandedFrame, display: true)
        panel.layoutIfNeeded()
        panel.orderFrontRegardless()
        if keyboard { panel.makeKey() }
        if model.settings.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(self.motion(.spring(response: 0.30, dampingFraction: 0.86))) { self.model.expanded = true }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.expanded else { return }
                withAnimation(self.motion(.easeOut(duration: 0.18))) { self.model.contentVisible = true }
            }
            self.reveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    func focusForEditing() { panel.makeKey() }

    #if DEBUG
    func showNativePromiseTest(destination: URL) {
        model.expanded = true; model.contentVisible = true
        panel.orderOut(nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 676, height: 458), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Disposable move test"
        window.contentView = NSHostingView(rootView: NativePromiseTestView(model: model, destination: destination))
        window.center()
        nativePromiseTestWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    #endif

    func collapse(force: Bool = false) {
        opening?.cancel(); opening = nil
        closing?.cancel(); closing = nil
        guard model.expanded else { return }
        #if DEBUG
        if model.pinOpenForSmokeTest && !force { return }
        #endif
        if !force && (model.dropTargeted || model.hub.editing || model.activeDragSource != nil) { return }
        reveal?.cancel()
        withAnimation(motion(.easeOut(duration: 0.1))) { model.contentVisible = false }
        withAnimation(motion(.spring(response: 0.25, dampingFraction: 0.9)), completionCriteria: .removed) {
            model.expanded = false
        } completion: { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.panel.setFrame(self.geometry.restingFrame, display: true)
            self.panel.level = .statusBar
            self.panel.resignKey()
        }
    }

    private func motion(_ animation: Animation) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.1) : animation
    }

    func shutdown() {
        opening?.cancel(); closing?.cancel(); reveal?.cancel()
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors.removeAll()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll(); subscriptions.removeAll()
        panel.contentView = nil; panel.orderOut(nil)
    }
}
