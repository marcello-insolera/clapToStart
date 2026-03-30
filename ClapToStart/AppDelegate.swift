import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController!
    private var clapDetector: ClapDetector!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as background/menu-bar-only app — no Dock icon
        NSApp.setActivationPolicy(.accessory)

        clapDetector = ClapDetector()
        statusBarController = StatusBarController(clapDetector: clapDetector)

        clapDetector.onClapDetected = { [weak self] in
            self?.openClaude()
        }

        clapDetector.start()
    }

    // MARK: - Open Claude

    private func openClaude() {
        let candidates = [
            "/Applications/Claude.app",
            "\(NSHomeDirectory())/Applications/Claude.app"
        ]

        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
                return
            }
        }

        // Fallback: open claude.ai in the default browser
        if let url = URL(string: "https://claude.ai") {
            NSWorkspace.shared.open(url)
        }
    }
}
