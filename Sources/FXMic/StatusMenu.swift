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

        let toggle = NSMenuItem(title: controller.state == .idle ? "Start listening" : "Stop listening", action: #selector(toggleArmed), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let shake = NSMenuItem(title: "Shake to cancel", action: #selector(toggleShake), keyEquivalent: "")
        shake.target = self; shake.state = Settings.shared.shakeToCancel ? .on : .off
        menu.addItem(shake)

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

        if !ComposerDelivery.isTrusted {
            let grant = NSMenuItem(title: "Grant Accessibility access…", action: #selector(grantAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        menu.addItem(.separator())
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

    @objc private func toggleShake() { Settings.shared.shakeToCancel.toggle(); controller.snapshot() }
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
    @objc private func grantAccessibility() { ComposerDelivery.requestAccess() }
    @objc private func quit() { NSApp.terminate(nil) }
}
