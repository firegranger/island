import AppKit
import ServiceManagement
import os

let log = Logger(subsystem: "com.antho.island", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = IslandModel()
    private let keys = MediaKeyTap()
    private let notifications = NotificationWatcher()
    private var controls: SystemControls!
    private var controller: IslandController!
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Si le pont musique meurt, une écriture dans son stdin ne doit pas tuer l'app.
        signal(SIGPIPE, SIG_IGN)
        // Sans fenêtre visible, macOS mettrait l'app en sommeil (App Nap) et retarderait l'îlot.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Îlot dynamique")

        controller = IslandController(model: model)
        controller.menuProvider = { [unowned self] in makeMenu() }

        model.media.start()

        controls = SystemControls(model: model)
        keys.handler = { [unowned self] key, fine in controls.handle(key, fine: fine) }
        keys.start()

        notifications.onNotification = { [weak model] banner in model?.show(banner) }
        notifications.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.media.stop()
    }

    // MARK: - Menu (clic droit sur l'encoche)

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let login = NSMenuItem(title: "Ouvrir à l'ouverture de session", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        if !keys.isActive {
            let item = NSMenuItem(title: "Autoriser les touches volume et luminosité…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !notifications.isAuthorized {
            let item = NSMenuItem(title: "Autoriser les notifications…", action: #selector(openFullDiskAccessSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            log.error("Ouverture de session : \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func openAccessibilitySettings() {
        keys.start()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
