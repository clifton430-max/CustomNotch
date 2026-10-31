import AppKit

@main
enum CustomNotchMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller.show()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.portrait.fill",
                                           accessibilityDescription: "CustomNotch")
        let menu = NSMenu()
        let reset = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "r")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CustomNotch", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func resetPosition() { controller.resetPosition() }

    @objc private func quit() {
        controller.dismiss { NSApp.terminate(nil) }
    }
}
