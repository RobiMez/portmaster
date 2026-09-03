import Foundation
import Combine

private let activeIntervalKey = "scanIntervalActive"
private let idleIntervalKey = "scanIntervalIdle"

/// User-adjustable preferences, persisted across launches.
final class AppSettings: ObservableObject {
    /// Seconds between scans while the island or popover is open.
    @Published var activeInterval: TimeInterval =
        UserDefaults.standard.object(forKey: activeIntervalKey) as? TimeInterval ?? 2 {
        didSet { UserDefaults.standard.set(activeInterval, forKey: activeIntervalKey) }
    }

    /// Seconds between scans while collapsed / in the background.
    @Published var idleInterval: TimeInterval =
        UserDefaults.standard.object(forKey: idleIntervalKey) as? TimeInterval ?? 15 {
        didSet { UserDefaults.standard.set(idleInterval, forKey: idleIntervalKey) }
    }
}
