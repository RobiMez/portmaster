import AppKit
import Combine
import SwiftUI

/// Presents PortMaster as a menu bar extra: a status item whose left-click
/// opens a popover with the shared port list, and whose right-click offers a
/// small menu (switch back to the notch, quit). Reachable on any display.
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let state: IslandState
    private let scanner: PortScanner
    private let openSettingsAction: () -> Void

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(state: IslandState, scanner: PortScanner, openSettings: @escaping () -> Void) {
        self.state = state
        self.scanner = scanner
        self.openSettingsAction = openSettings
        super.init()

        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: MenuBarPopoverView(state: state, scanner: scanner, openSettings: openSettings)
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    // MARK: - Lifecycle

    func activate() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "network",
                accessibilityDescription: "PortMaster listening ports"
            )
            button.imagePosition = .imageLeading
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            button.action = #selector(handleClick)
        }
        statusItem = item
        updateTitle(state.portCount)

        // Keep the port count in the menu bar fresh.
        state.$portCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateTitle($0) }
            .store(in: &cancellables)
    }

    func deactivate() {
        cancellables.removeAll()
        if popover.isShown { popover.performClose(nil) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func updateTitle(_ count: Int) {
        statusItem?.button?.title = " \(count)"
    }

    // MARK: - Interaction

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            scanner.scanNow()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Use Notch Mode", action: #selector(switchToNotch), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PortMaster", action: #selector(quit), keyEquivalent: "q")
            .target = self

        // Attach transiently so left-click keeps opening the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func switchToNotch() {
        state.mode = .notch
    }

    @objc private func openSettings() {
        openSettingsAction()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        scanner.setActive(true)
    }

    func popoverDidClose(_ notification: Notification) {
        scanner.setActive(false)
    }
}
