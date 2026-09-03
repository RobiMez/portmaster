import SwiftUI

/// Native-styled settings content: a General tab (login item, display mode,
/// scan frequency) and an About tab. Uses system fonts and controls — the
/// Lexend/black-island styling is deliberately confined to the island UI.
struct SettingsView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var settings: AppSettings
    @ObservedObject var loginItem: LoginItemModel

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .disabled(!LoginItemModel.isSupported)
                if !LoginItemModel.isSupported {
                    footnote("Available in the built app (./build.sh).")
                } else if let note = loginItem.note {
                    footnote(note)
                }
            }

            Section("Appearance") {
                Picker("Show in", selection: $state.mode) {
                    Text("Notch").tag(AppMode.notch)
                    Text("Menu Bar").tag(AppMode.menuBar)
                }
                .pickerStyle(.segmented)
            }

            Section("Scanning") {
                Picker("While open", selection: $settings.activeInterval) {
                    Text("1 second").tag(TimeInterval(1))
                    Text("2 seconds").tag(TimeInterval(2))
                    Text("5 seconds").tag(TimeInterval(5))
                }
                Picker("In background", selection: $settings.idleInterval) {
                    Text("5 seconds").tag(TimeInterval(5))
                    Text("15 seconds").tag(TimeInterval(15))
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                }
                footnote("How often PortMaster refreshes the list of listening ports.")
            }
        }
        .formStyle(.grouped)
        // Match the About tab: drop the grouped form's own (lighter) backdrop
        // so both tabs sit on the plain window background with no seam under
        // the tab bar.
        .scrollContentBackground(.hidden)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text(AppInfo.name)
                .font(.title2.weight(.semibold))
            Text("Version \(AppInfo.displayVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("See what's listening on your Mac, right from the notch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link("GitHub Repository", destination: AppInfo.repoURL)
                .font(.callout)
                .padding(.top, 4)
            Text("© 2026 RobiMez")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}
