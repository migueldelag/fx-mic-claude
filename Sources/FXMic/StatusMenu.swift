import AppKit
import FXMicCore
import ServiceManagement

final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FXMic")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "FXMic: \(controller.state.rawValue). Click to \(controller.state == .idle ? "pick up" : "hang up"), right-click for the menu."
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "FXMic: \(controller.state.rawValue)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let error = controller.lastError {
            let e = NSMenuItem(title: error, action: nil, keyEquivalent: ""); e.isEnabled = false; menu.addItem(e)
        }
        if let device = controller.deviceName {
            let d = NSMenuItem(title: "Input: \(device)" + (controller.transcriberReady ? "" : "  (loading speech models)"), action: nil, keyEquivalent: "")
            d.isEnabled = false
            menu.addItem(d)
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: controller.state == .idle ? "Start listening" : "Stop listening", action: #selector(toggleArmed), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let hint = NSMenuItem(title: "Shortcut: ⌃⌥Space", action: nil, keyEquivalent: ""); hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let targetTitle = controller.dispatcher.currentTarget?.title ?? "clipboard (no session armed)"
        let targetsItem = NSMenuItem(title: "Send to: \(targetTitle)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = controller.dispatcher.currentTarget?.id
        for t in controller.dispatcher.targets.sorted(by: { $0.armedAt > $1.armedAt }) {
            let mi = NSMenuItem(title: "\(t.title)  —  \((t.cwd as NSString).abbreviatingWithTildeInPath)", action: #selector(selectTarget(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = t.id
            mi.state = t.id == current ? .on : .off
            sub.addItem(mi)
        }
        if controller.dispatcher.targets.isEmpty {
            let none = NSMenuItem(title: "No sessions armed. Run /fxmic in a Claude Code session.", action: nil, keyEquivalent: ""); none.isEnabled = false
            sub.addItem(none)
        }
        sub.addItem(.separator())
        let auto = NSMenuItem(title: "Most recently armed", action: #selector(selectTarget(_:)), keyEquivalent: "")
        auto.target = self; auto.representedObject = nil; auto.state = Settings.shared.selectedTargetID == nil ? .on : .off
        sub.addItem(auto)
        let reload = NSMenuItem(title: "Reload", action: #selector(reloadTargets), keyEquivalent: ""); reload.target = self
        sub.addItem(reload)
        targetsItem.submenu = sub
        menu.addItem(targetsItem)

        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        if controller.recent.isEmpty {
            let none = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: ""); none.isEnabled = false
            recentMenu.addItem(none)
        }
        for r in controller.recent {
            let title = r.text.count > 60 ? String(r.text.prefix(60)) + "…" : r.text
            let mi = NSMenuItem(title: title, action: #selector(copyRecent(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = r.text; mi.toolTip = "\(r.outcome). Click to copy."
            recentMenu.addItem(mi)
        }
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        menu.addItem(.separator())

        let composer = NSMenuItem(title: "Type into Claude's composer" + (ComposerDelivery.isTrusted ? "" : "  (needs Accessibility)"), action: #selector(toggleComposer), keyEquivalent: "")
        composer.target = self; composer.state = Settings.shared.composerDelivery ? .on : .off
        menu.addItem(composer)
        if !ComposerDelivery.isTrusted {
            let grant = NSMenuItem(title: "Grant Accessibility access…", action: #selector(grantAccessibility), keyEquivalent: ""); grant.target = self
            menu.addItem(grant)
        }
        let testSend = NSMenuItem(title: "Send a test message to Claude", action: #selector(testSend), keyEquivalent: ""); testSend.target = self
        menu.addItem(testSend)
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
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundleIdentifier != nil
        menu.addItem(login)
        let hudToggle = NSMenuItem(title: "Show HUD", action: #selector(toggleHUD), keyEquivalent: "")
        hudToggle.target = self; hudToggle.state = Settings.shared.hudEnabled ? .on : .off
        menu.addItem(hudToggle)
        let test = NSMenuItem(title: "Test HUD", action: #selector(testHUD), keyEquivalent: ""); test.target = self
        menu.addItem(test)
        let newSession = NSMenuItem(title: "New Claude Code session", action: #selector(newSession), keyEquivalent: ""); newSession.target = self
        menu.addItem(newSession)
        let finder = NSMenuItem(title: "Open ~/.fxmic", action: #selector(openFolder), keyEquivalent: ""); finder.target = self
        menu.addItem(finder)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FXMic", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleArmed() { controller.toggleArmed() }
    @objc private func reloadTargets() { controller.dispatcher.reload() }
    @objc private func selectTarget(_ sender: NSMenuItem) { controller.dispatcher.select(sender.representedObject as? String) }
    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if wantsMenu {
            item.menu = menu           // attach only for this click so the next left click toggles again
            sender.performClick(nil)
            item.menu = nil
        } else {
            controller.toggleArmed()
        }
    }

    @objc private func toggleHUD() { Settings.shared.hudEnabled.toggle() }
    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.shared.deviceQuery = name
        Log.write("input device set to \(name)")
        if controller.state != .idle { controller.disarm(reason: "Switching input"); controller.arm() }
        refresh()
    }
    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            Log.write("launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
        } catch { Log.write("launch at login failed: \(error)") }
    }
    @objc private func toggleComposer() { Settings.shared.composerDelivery.toggle(); controller.snapshot() }
    @objc private func grantAccessibility() { ComposerDelivery.requestAccess() }
    @objc private func testSend() { controller.deliverText("Test message from FXMic at \(Date().formatted(date: .omitted, time: .standard)).") }
    @objc private func testHUD() {
        controller.hud.listening(target: controller.dispatcher.currentTarget?.title ?? "clipboard")
        controller.hud.partial("This is what a live transcript looks like while you talk.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.controller.hud.sent("This is what a live transcript looks like while you talk.", outcome: "Sent to Test session") }
    }
    @objc private func newSession() { controller.newSession() }
    @objc private func openFolder() { NSWorkspace.shared.open(controller.dispatcher.root) }
    @objc private func quit() { NSApp.terminate(nil) }
}
