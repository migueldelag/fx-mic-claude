import AppKit
import FXMicCore
import ServiceManagement

final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    enum Activity { case none, thinking, done }
    private var activity: Activity = .none
    private var dotTimer: Timer?
    private var dotPhase = 0
    private var doneReset: DispatchWorkItem?

    /// Draws the handset with optional dots (task in progress) or a check (task done), as a template image.
    private static func compose(base: String, dots: Int = 0, check: Bool = false) -> NSImage {
        let extra: CGFloat = (dots > 0 || check) ? 14 : 0
        let size = NSSize(width: 18 + extra, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            if let phone = NSImage(systemSymbolName: base, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let pr = NSRect(x: (18 - phone.size.width) / 2, y: (18 - phone.size.height) / 2, width: phone.size.width, height: phone.size.height)
                phone.draw(in: pr)
            }
            NSColor.black.setFill()
            for i in 0..<dots {
                NSBezierPath(ovalIn: NSRect(x: 19 + CGFloat(i) * 4.5, y: 7.5, width: 3, height: 3)).fill()
            }
            if check, let mark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)) {
                mark.draw(in: NSRect(x: 19, y: (18 - mark.size.height) / 2, width: mark.size.width, height: mark.size.height))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Task-progress decoration on the icon: dots while Claude works, a check for two seconds when it finishes.
    func setActivity(_ a: Activity) {
        activity = a
        dotTimer?.invalidate(); dotTimer = nil
        doneReset?.cancel(); doneReset = nil
        switch a {
        case .thinking:
            dotPhase = 0
            dotTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.dotPhase = (self.dotPhase % 3) + 1
                self.refresh()
            }
        case .done:
            let reset = DispatchWorkItem { [weak self] in self?.setActivity(.none) }
            doneReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: reset)
        case .none:
            break
        }
        refresh()
    }
    private unowned let controller: AppController
    private let menu = NSMenu()

    init(controller: AppController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        // Left click picks up or hangs up; right click (or control-click) opens the menu.
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()
        controller.onStateChange = { [weak self] in self?.refresh() }
        controller.dispatcher.onTargetsChanged = { [weak self] in self?.refresh() }
    }

    func refresh() {
        let symbol: String
        switch controller.state {
        case .idle: symbol = Settings.shared.iconIdle
        case .armed: symbol = Settings.shared.iconArmed
        case .listening: symbol = Settings.shared.iconListening
        }
        switch activity {
        case .thinking: item.button?.image = StatusMenu.compose(base: symbol, dots: max(1, dotPhase))
        case .done: item.button?.image = StatusMenu.compose(base: symbol, check: true)
        case .none: item.button?.image = StatusMenu.compose(base: symbol)
        }
        item.button?.toolTip = "FXMic: \(controller.state.rawValue). Click to \(controller.state == .idle ? "pick up" : "hang up"), right-click for the menu."
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 1. listening toggle
        let toggle = NSMenuItem(title: controller.state == .idle ? "Start listening" : "Stop listening", action: #selector(toggleArmed), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // 2. input device
        let deviceMenu = NSMenu()
        let currentDevice = Settings.shared.deviceQuery
        for dev in AudioDevices.inputs() {
            let item = NSMenuItem(title: dev.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = dev.name
            item.state = (dev.name == currentDevice || dev.uid == currentDevice || dev.name.localizedCaseInsensitiveContains(currentDevice)) ? .on : .off
            deviceMenu.addItem(item)
        }
        let deviceItem = NSMenuItem(title: "Input device", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)
        menu.addItem(.separator())

        // 3. target session, shown by (truncated) name
        let targetMenu = NSMenu()
        let recent = SessionStore.recent(limit: 5)
        let effective = Settings.shared.targetSessionTitle ?? recent.first?.title
        for session in recent {
            let item = NSMenuItem(title: session.title, action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = session.title
            item.state = session.title == effective ? .on : .off
            targetMenu.addItem(item)
        }
        let shown = effective.map { $0.count > 24 ? String($0.prefix(24)).trimmingCharacters(in: .whitespaces) + "…" : $0 } ?? "current session"
        let targetItem = NSMenuItem(title: "Target: \(shown)", action: nil, keyEquivalent: "")
        targetItem.submenu = targetMenu
        menu.addItem(targetItem)
        menu.addItem(.separator())

        // 4. options
        let shake = NSMenuItem(title: "Shake to cancel", action: #selector(toggleShake), keyEquivalent: "")
        shake.target = self; shake.state = Settings.shared.shakeToCancel ? .on : .off
        menu.addItem(shake)
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundleIdentifier != nil
        menu.addItem(login)
        if !ComposerDelivery.isTrusted {
            let grant = NSMenuItem(title: "Grant Accessibility access…", action: #selector(grantAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        menu.addItem(.separator())

        // 5. quit
        let quitItem = NSMenuItem(title: "Quit FXMic", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleArmed() { controller.toggleArmed(source: "menu item") }
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if wantsMenu {
            item.menu = menu           // attach only for this click so the next left click toggles again
            sender.performClick(nil)
            item.menu = nil
        } else {
            controller.toggleArmed(source: "menu bar click")
        }
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        let title = sender.representedObject as? String ?? ""
        Settings.shared.targetSessionTitle = title.isEmpty ? nil : title
        Log.write("target: \(title.isEmpty ? "last used" : title)")
        controller.snapshot()
    }
    @objc private func toggleShake() { Settings.shared.shakeToCancel.toggle(); controller.snapshot() }
    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.shared.deviceQuery = name
        Log.write("input device set to \(name)")
        if controller.state != .idle { controller.disarm(reason: "Switching input") }
        controller.arm()            // picking a device means: listen on it
        refresh()
    }
    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            Log.write("launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
        } catch { Log.write("launch at login failed: \(error)") }
    }
    @objc private func grantAccessibility() { ComposerDelivery.requestAccess() }
    @objc private func quit() { NSApp.terminate(nil) }
}
