import AppKit
import Combine
import HeadsUpCore
import SwiftUI

final class HeadsUpPanel: NSPanel {
    // Never take keyboard focus from the app the user is working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the square desktop panel.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let minSide: CGFloat = 220
    static let maxSide: CGFloat = 900
    static let defaultSide: CGFloat = 360

    let panel: HeadsUpPanel
    private let model: AppModel
    private var bag = Set<AnyCancellable>()
    private var restored = false
    private var zoomMonitor: Any?
    var onVisibilityChange: ((Bool) -> Void)?

    init(model: AppModel, actions: PanelActions) {
        self.model = model
        panel = HeadsUpPanel(contentRect: NSRect(x: 0, y: 0, width: Self.defaultSide, height: Self.defaultSide),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = "HeadsUp"
        panel.delegate = self
        panel.contentAspectRatio = NSSize(width: 1, height: 1)

        var acts = actions
        acts.resize = { [weak self] side in self?.setSide(side) }
        let host = NSHostingView(rootView: PanelView(model: model, actions: acts))
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host

        if let f = model.settings.panelFrame {
            panel.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[2]), display: false)
        } else {
            placeDefault()
        }
        clampToScreen()
        restored = true

        // Trackpad pinch over the panel zooms the map. A local monitor sees the gesture wherever the
        // pointer is in the panel, before SwiftUI's hosting view can swallow it.
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            if ProcessInfo.processInfo.environment["HEADSUP_TEST_CONTROL"] == "1" {
                FileHandle.standardError.write("magnify window=\(String(describing: event.window?.windowNumber)) loc=\(event.locationInWindow) mag=\(event.magnification) phase=\(event.phase.rawValue)\n".data(using: .utf8)!)
            }
            guard let self, self.model.settings.mapDragEnabled,
                  event.window === self.panel || (event.window == nil && self.panel.frame.contains(NSEvent.mouseLocation))
            else { return event }
            let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            self.model.zoom(to: self.model.displayRadius / max(0.2, 1 + event.magnification), final: ended)
            return nil
        }

        model.settings.$panelLevel.sink { [weak self] in self?.apply(level: $0) }.store(in: &bag)
        model.settings.$appearance.sink { [weak self] in self?.apply(appearance: $0) }.store(in: &bag)
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        onVisibilityChange?(true)
    }

    func hide() {
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }

    func toggle() { isVisible ? hide() : show() }

    var side: CGFloat { panel.frame.width }

    /// Resizes the square, keeping the top-left corner fixed.
    func setSide(_ side: CGFloat) {
        let s = min(max(side.rounded(), Self.minSide), Self.maxSide)
        var f = panel.frame
        let top = f.maxY
        f.size = NSSize(width: s, height: s)
        f.origin.y = top - s
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    private func placeDefault() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let s = Self.defaultSide
        panel.setFrame(NSRect(x: v.maxX - s - 28, y: v.maxY - s - 28, width: s, height: s), display: false)
    }

    /// Keeps a restored frame square and on a screen that still exists.
    private func clampToScreen() {
        var f = panel.frame
        let s = min(max(min(f.width, f.height), Self.minSide), Self.maxSide)
        f.size = NSSize(width: s, height: s)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(f.insetBy(dx: 40, dy: 40)) }
        panel.setFrame(f, display: false)
        if !onScreen { placeDefault() }
    }

    private func apply(level: PanelLevel) {
        switch level {
        case .desktop:
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .normal:
            panel.level = .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        case .floating:
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
        if panel.isVisible { panel.orderFrontRegardless() }
    }

    private func apply(appearance: AppearanceMode) {
        let a: NSAppearance?
        switch appearance {
        case .system: a = nil
        case .light: a = NSAppearance(named: .aqua)
        case .dark: a = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = a
        panel.invalidateShadow()
    }

    // MARK: NSWindowDelegate

    func windowDidChangeOcclusionState(_ notification: Notification) {
        onVisibilityChange?(panel.occlusionState.contains(.visible))
    }

    func windowDidResize(_ notification: Notification) {
        panel.invalidateShadow()
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard restored else { return }
        let f = panel.frame
        model.settings.panelFrame = [f.origin.x, f.origin.y, f.width]
    }
}
