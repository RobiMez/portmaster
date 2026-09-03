import AppKit
import SwiftUI

/// Owns the single settings window. The window is created lazily on first
/// show and kept alive across close/reopen; a second `show()` just fronts it.
final class SettingsWindowController {
    private let state: IslandState
    private let settings: AppSettings
    private let loginItem = LoginItemModel()
    private var window: NSWindow?

    init(state: IslandState, settings: AppSettings) {
        self.state = state
        self.settings = settings
    }

    func show() {
        loginItem.refresh()
        if window == nil { window = makeWindow() }
        // Accessory app: without an explicit activate the window would appear
        // behind whatever app is frontmost and never take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsView(state: state, settings: settings, loginItem: loginItem)
        )
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "PortMaster Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PortMasterSettings")
        return window
    }
}
