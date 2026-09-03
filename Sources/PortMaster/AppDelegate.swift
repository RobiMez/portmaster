import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = IslandState()
    private let scanner = PortScanner()
    private let settings = AppSettings()
    private var windowController: NotchWindowController?
    private var menuBarController: MenuBarController?
    private var settingsController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotchWindowController(state: state, scanner: scanner) { [weak self] in
            self?.showSettings()
        }
        windowController = controller

        // Keep the island's height + collapsed badge in sync with the scan.
        scanner.$ports
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ports in
                guard let self else { return }
                self.state.portCount = ports.count
                let devGroups = groupPortsByOwner(ports.filter { $0.isDevServer })
                let systemGroups = groupPortsByOwner(ports.filter { !$0.isDevServer })
                self.state.visibleSectionCount =
                    (devGroups.isEmpty ? 0 : 1) + (systemGroups.isEmpty ? 0 : 1)
                self.state.contentHeight = self.state.measuredContentHeight(
                    devGroups: devGroups, systemGroups: systemGroups)
            }
            .store(in: &cancellables)

        // Scan faster while the island is open.
        state.$isExpanded
            .removeDuplicates()
            .sink { [weak self] in self?.scanner.setActive($0) }
            .store(in: &cancellables)

        // Re-arm the scan timer when the user changes the frequency settings.
        // @Published replays current values on subscription, so the persisted
        // intervals apply before start() schedules the first scan.
        settings.$activeInterval
            .combineLatest(settings.$idleInterval)
            .sink { [weak self] in self?.scanner.updateIntervals(active: $0, idle: $1) }
            .store(in: &cancellables)

        // Show the surface matching the persisted (or default) mode.
        state.$mode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyMode($0) }
            .store(in: &cancellables)

        // Follow display changes (lid open/close, external monitors).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.positionWindow() }

        // A click anywhere outside the island collapses it, even when pinned.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.state.isExpanded else { return }
            self.state.collapse()
        }

        scanner.start()

        if ProcessInfo.processInfo.environment["PORTMASTER_START_EXPANDED"] == "1" {
            state.isPinned = true
            state.isExpanded = true
        }

        if ProcessInfo.processInfo.environment["PORTMASTER_OPEN_SETTINGS"] == "1" {
            showSettings()
        }
    }

    /// Switch to the requested surface, hiding the other one.
    private func applyMode(_ mode: AppMode) {
        switch mode {
        case .notch:
            menuBarController?.deactivate()
            positionWindow()
        case .menuBar:
            windowController?.panel.orderOut(nil)
            if menuBarController == nil {
                menuBarController = MenuBarController(state: state, scanner: scanner) { [weak self] in
                    self?.showSettings()
                }
            }
            menuBarController?.activate()
        }
    }

    private func showSettings() {
        state.collapse()
        if settingsController == nil {
            settingsController = SettingsWindowController(state: state, settings: settings)
        }
        settingsController?.show()
    }

    private func positionWindow() {
        // In menu bar mode the notch panel stays hidden; a screen-change event
        // must not re-show it via orderFrontRegardless.
        guard state.mode == .notch,
              let screen = NotchWindowController.targetScreen(),
              let controller = windowController else { return }
        state.updateScreenMetrics(for: screen)
        controller.layout(on: screen)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }
}
