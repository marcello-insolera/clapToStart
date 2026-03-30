import Cocoa
import ServiceManagement

class StatusBarController {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let detector: ClapDetector

    init(clapDetector: ClapDetector) {
        self.detector = clapDetector
        configureButton()
        buildMenu()
    }

    // MARK: - Status-bar button

    private func configureButton() {
        guard let btn = item.button else { return }
        btn.image = icon(for: detector.isEnabled)
        btn.image?.isTemplate = true
        btn.toolTip = "ClapToStart"
    }

    private func icon(for enabled: Bool) -> NSImage? {
        NSImage(systemSymbolName: enabled ? "hands.clap.fill" : "hands.clap",
                accessibilityDescription: "ClapToStart")
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        // ── Header ───────────────────────────────────────────────────────────
        addDisabled("ClapToStart", to: menu, bold: true)
        let subtitle = detector.isEnabled
            ? "Aktiv – doppelt klatschen um Claude zu öffnen"
            : "Deaktiviert"
        addDisabled(subtitle, to: menu)
        menu.addItem(.separator())

        // ── Enable / Disable ─────────────────────────────────────────────────
        let toggle = NSMenuItem(
            title: detector.isEnabled ? "Deaktivieren" : "Aktivieren",
            action: #selector(toggleDetection),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        // ── Sensitivity sub-menu ─────────────────────────────────────────────
        let sensitivityItem = NSMenuItem(title: "Empfindlichkeit", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in ClapDetector.Sensitivity.allCases {
            let mi = NSMenuItem(title: s.rawValue, action: #selector(selectSensitivity(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s
            mi.state = (detector.sensitivity == s) ? .on : .off
            sub.addItem(mi)
        }
        sensitivityItem.submenu = sub
        menu.addItem(sensitivityItem)

        menu.addItem(.separator())

        // ── Launch at Login ───────────────────────────────────────────────────
        let loginEnabled = loginItemEnabled()
        let loginTitle = loginEnabled ? "Autostart deaktivieren" : "Beim Systemstart starten"
        let loginMI = NSMenuItem(title: loginTitle, action: #selector(toggleLoginItem), keyEquivalent: "")
        loginMI.target = self
        menu.addItem(loginMI)

        menu.addItem(.separator())

        // ── Quit ─────────────────────────────────────────────────────────────
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
    }

    private func addDisabled(_ title: String, to menu: NSMenu, bold: Bool = false) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if bold {
            mi.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
            )
        }
        mi.isEnabled = false
        menu.addItem(mi)
    }

    // MARK: - Actions

    @objc private func toggleDetection() {
        detector.isEnabled.toggle()
        item.button?.image = icon(for: detector.isEnabled)
        item.button?.image?.isTemplate = true
        buildMenu()
    }

    @objc private func selectSensitivity(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? ClapDetector.Sensitivity else { return }
        detector.sensitivity = s
        buildMenu()
    }

    @objc private func toggleLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                if loginItemEnabled() {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                showError(error)
            }
        } else {
            showLegacyLoginItemHint()
        }
        buildMenu()
    }

    // MARK: - Helpers

    private func loginItemEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Autostart konnte nicht konfiguriert werden"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showLegacyLoginItemHint() {
        let alert = NSAlert()
        alert.messageText = "Autostart einrichten"
        alert.informativeText = "Bitte füge ClapToStart manuell unter\nSystemeinstellungen → Allgemein → Anmeldeobjekte hinzu."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
