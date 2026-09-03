import Foundation

/// Static app metadata for the About tab and the build script.
enum AppInfo {
    /// Single source of truth — build.sh extracts VERSION from this line.
    static let version = "1.0.0"

    /// Prefers the bundle's Info.plist (present in the built .app); falls back
    /// to the constant under `swift run`, where there is no bundle.
    static var displayVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? version
    }

    static let name = "PortMaster"
    static let repoURL = URL(string: "https://github.com/RobiMez/portmaster")!
}
