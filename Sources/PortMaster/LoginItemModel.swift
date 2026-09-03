import Foundation
import ServiceManagement

/// Wraps SMAppService for the "Open at Login" toggle. The service's `status`
/// is the only source of truth — the user can flip it behind our back in
/// System Settings, so `refresh()` is called every time the window opens and
/// after every register/unregister attempt (a failed call snaps the toggle
/// back instead of drifting out of sync).
final class LoginItemModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var note: String?

    /// SMAppService needs a real .app bundle; under `swift run` there is none.
    /// Note: the app is ad-hoc signed, so a rebuilt or moved bundle can report
    /// `.notFound` for a previously registered item — re-toggling re-registers.
    static let isSupported = Bundle.main.bundleURL.pathExtension == "app"

    func refresh() {
        guard Self.isSupported else { return }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        note = status == .requiresApproval
            ? "Approval needed in System Settings › Login Items." : nil
    }

    func setEnabled(_ on: Bool) {
        guard Self.isSupported else { return }
        var failure: String?
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error.localizedDescription
        }
        refresh()
        if let failure { note = failure }
    }
}
