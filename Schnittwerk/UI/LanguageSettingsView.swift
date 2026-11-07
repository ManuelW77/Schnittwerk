// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings tab: app language (system, German, English). macOS reads the
// language only at launch, so a change needs a restart.

import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, de, en
    var id: String { rawValue }

    /// Names in their own language, so they can be found in any language.
    var title: String {
        switch self {
        case .system: String(localized: "Same as macOS")
        case .de: "Deutsch"
        case .en: "English"
        }
    }

    private static let key = "AppleLanguages"

    /// The choice stored for this app (not the macOS setting).
    static var current: AppLanguage {
        let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String]
        guard let first = list?.first else { return .system }
        return first.hasPrefix("de") ? .de : (first.hasPrefix("en") ? .en : .system)
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
    }

    /// Quits and starts the app again. If quitting is cancelled (e.g. to
    /// save a project), the app is not started a second time.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "for i in $(seq 1 300); do kill -0 \(pid) 2>/dev/null || { open \"$0\"; exit 0; }; sleep 0.2; done"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

struct LanguageSettingsView: View {
    @State private var choice = AppLanguage.current
    /// Language the app was started with.
    @State private var started = AppLanguage.current

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $choice) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .onChange(of: choice) { choice.apply() }
                if choice != started {
                    HStack {
                        Label("Takes effect after a restart.", systemImage: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart now") { AppLanguage.relaunch() }
                    }
                }
            } footer: {
                Text("“Same as macOS” follows System Settings → General → Language & Region.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
