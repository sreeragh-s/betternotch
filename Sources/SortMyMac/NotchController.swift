import AppKit
import Combine
import SortMyMacCore
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Shadow margins should never catch a click intended for the application below.
        if point.x < 28 || point.x > bounds.width - 28 || point.y < 28 { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class NotchController {
    private let model: AppModel
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var opening: DispatchWorkItem?
    private var closing: DispatchWorkItem?
    private var reveal: DispatchWorkItem?
    private var geometry: NotchGeometry { model.geometry }

    init(model: AppModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NotchHostingView(rootView: NotchView(model: model))
        panel.dismiss = { [weak self] in self?.collapse(force: true) }
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
        model.geometry = NotchGeometry(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                                       leftWidth: screen.auxiliaryTopLeftArea?.width,
                                       rightWidth: screen.auxiliaryTopRightArea?.width)
        panel.setFrame(model.expanded ? geometry.expandedFrame : geometry.restingFrame, display: true)
        panel.orderFrontRegardless()
    }

    static func identifier(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
    }

    private func track(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
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
            expand(immediate: event.type == .leftMouseDragged)
        } else { opening?.cancel(); opening = nil }
    }

    func expand(immediate: Bool = false, keyboard: Bool = false) {
        closing?.cancel(); closing = nil
        guard !model.expanded else { if keyboard { panel.makeKey() }; return }
        if !immediate {
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

    func collapse(force: Bool = false) {
        opening?.cancel(); opening = nil
        closing?.cancel(); closing = nil
        guard model.expanded else { return }
        if !force && (model.phase == .analyzing || model.phase == .exporting) { return }
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
