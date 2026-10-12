import AppKit
import HeadsUpCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var model: AppModel!
    private(set) var panel: PanelController!
    private(set) var settingsWindow: SettingsWindowController!
    private var statusItem: NSStatusItem?
    private var testControl: TestControl?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let defaults = env["HEADSUP_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
        let settings = SettingsStore(defaults: defaults)

        let feeds: [FlightFeed]
        if let base = env["HEADSUP_FEED_BASE"] {
            feeds = [ReadsbFeed.adsbLol(base: base)]
        } else {
            feeds = [ReadsbFeed.adsbLol(), ReadsbFeed.adsbFi()]
        }
        let tracker = FlightTracker(feeds: feeds, radiusKm: settings.radiusKm)
        let routes = env["HEADSUP_ROUTE_BASE"].map { RouteService(base: $0) } ?? RouteService()
        let location = LocationService()
        model = AppModel(settings: settings, location: location, tracker: tracker, routes: routes)

        settingsWindow = SettingsWindowController { [unowned self] in
            AnyView(SettingsView(model: model, settings: settings, location: location, tracker: tracker,
                                 panelSide: { [unowned self] in panel.side },
                                 setPanelSide: { [unowned self] in panel.setSide($0) }))
        }

        let actions = PanelActions(
            openSettings: { [unowned self] in settingsWindow.show() },
            hidePanel: { [unowned self] in panel.hide() },
            contextMenu: { [unowned self] in buildMenu(forStatusItem: false) }
        )
        panel = PanelController(model: model, actions: actions)
        panel.onVisibilityChange = { [weak self] visible in
            self?.model.tracker.isPaused = !visible
        }

        setUpStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.tracker.isPaused = true }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.tracker.isPaused = !self.panel.isVisible
            }
        }

        if env["HEADSUP_NO_LOCATION"] == nil { location.start() }
        panel.show()
        tracker.refreshNow()

        if env["HEADSUP_TEST_CONTROL"] == "1" {
            testControl = TestControl(app: self)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return true
    }

    // MARK: Menus

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "airplane", accessibilityDescription: "HeadsUp")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu(forStatusItem: true).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    func buildMenu(forStatusItem: Bool) -> NSMenu {
        let menu = NSMenu()
        let count = model.tracker.aircraft.count
        let header = NSMenuItem(title: "\(count) 架飞机 · \(Format.km(model.settings.radiusKm)) 公里内", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        if forStatusItem {
            menu.addItem(item(panel.isVisible ? "隐藏面板" : "显示面板") { [unowned self] in panel.toggle() })
        } else {
            menu.addItem(item("隐藏面板") { [unowned self] in panel.hide() })
        }
        menu.addItem(item("立即刷新") { [unowned self] in model.tracker.refreshNow() })

        let radius = NSMenu()
        for r in [10.0, 20, 30, 50, 100] {
            let i = item("\(Int(r)) 公里") { [unowned self] in model.settings.radiusKm = r }
            i.state = model.settings.radiusKm == r ? .on : .off
            radius.addItem(i)
        }
        let radiusItem = NSMenuItem(title: "追踪半径", action: nil, keyEquivalent: "")
        radiusItem.submenu = radius
        menu.addItem(radiusItem)

        let look = NSMenu()
        for (title, mode) in [("跟随系统", AppearanceMode.system), ("浅色", .light), ("深色", .dark)] {
            let i = item(title) { [unowned self] in model.settings.appearance = mode }
            i.state = model.settings.appearance == mode ? .on : .off
            look.addItem(i)
        }
        let lookItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        lookItem.submenu = look
        menu.addItem(lookItem)

        let level = NSMenu()
        for (title, l) in [("桌面（在其他窗口下方）", PanelLevel.desktop), ("普通窗口", .normal), ("始终置顶", .floating)] {
            let i = item(title) { [unowned self] in model.settings.panelLevel = l }
            i.state = model.settings.panelLevel == l ? .on : .off
            level.addItem(i)
        }
        let levelItem = NSMenuItem(title: "窗口层级", action: nil, keyEquivalent: "")
        levelItem.submenu = level
        menu.addItem(levelItem)

        menu.addItem(.separator())
        menu.addItem(item("设置…", key: ",") { [unowned self] in settingsWindow.show() })
        menu.addItem(.separator())
        menu.addItem(item("退出 HeadsUp", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    private func item(_ title: String, key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, keyEquivalent: key, handler: action)
        return i
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
