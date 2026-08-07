import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var playerWindowController: PlayerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let controller = PlayerWindowController()
        playerWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let window = controller.window, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "LibreTube VOT")
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Выйти из LibreTube VOT",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "Вид")
        viewMenuItem.submenu = viewMenu
        let fullScreenItem = NSMenuItem(
            title: "Полноэкранный режим",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        NSApp.mainMenu = mainMenu
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
