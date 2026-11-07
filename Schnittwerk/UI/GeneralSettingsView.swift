// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings tab "General": app language (system, German, English) and
// light or dark look. macOS reads the language only at launch, so a
// language change needs a restart; the look changes at once.

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

/// Light or dark look, or the same as macOS. Takes effect at once.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    static let storageKey = "appearance"

    var title: String {
        switch self {
        case .system: String(localized: "Same as macOS")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    static var stored: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// What a new project starts with (Settings → General).
enum NewProjectDefaults {
    static let matKey = "new.mat"
    static let profile1Key = "new.profile1"
    static let profile2Key = "new.profile2"
    /// Show the cut preview before every cut.
    static let previewFirstKey = "cut.previewFirst"
    /// Value of the pickers for "what was set last" (also the default).
    static let lastUsed = "last"

    private static let lastMatKey = "last.mat"
    private static func lastSettingsKey(_ slot: Int) -> String { "last.settings\(slot)" }

    /// Remembers mat and tool values of the project worked on last.
    static func remember(_ data: ProjectData) {
        let d = UserDefaults.standard
        d.set(data.mat.rawValue, forKey: lastMatKey)
        for slot in [1, 2] {
            if let json = try? JSONEncoder().encode(data.settings(slot: slot)) {
                d.set(json, forKey: lastSettingsKey(slot))
            }
        }
    }

    static var lastMat: MatType? {
        UserDefaults.standard.string(forKey: lastMatKey).flatMap(MatType.init)
    }

    static func lastSettings(slot: Int) -> CutSettings? {
        UserDefaults.standard.data(forKey: lastSettingsKey(slot)).flatMap { try? JSONDecoder().decode(CutSettings.self, from: $0) }
    }

    /// Applies a built-in preset or own profile by its id.
    @MainActor
    static func apply(_ id: String?, to settings: inout CutSettings) {
        guard let id else { return }
        if let p = MaterialPreset.all.first(where: { $0.id == id }) {
            p.apply(to: &settings)
        } else if let p = ProfileStore.shared.profile(settingsID: id) {
            p.apply(to: &settings)
        }
    }
}

extension CutDocument {
    /// A new, empty project with the defaults from the settings.
    @MainActor
    static func newProject() -> CutDocument {
        let doc = CutDocument()
        let d = UserDefaults.standard
        let last = NewProjectDefaults.lastUsed
        let matChoice = d.string(forKey: NewProjectDefaults.matKey) ?? last
        if matChoice == last {
            if let mat = NewProjectDefaults.lastMat { doc.data.mat = mat }
        } else if let mat = MatType(rawValue: matChoice) {
            doc.data.mat = mat
        }
        for (slot, key) in [(1, NewProjectDefaults.profile1Key), (2, NewProjectDefaults.profile2Key)] {
            let choice = d.string(forKey: key) ?? last
            if choice == last {
                // Nothing remembered yet: the built-in defaults stay
                if let s = NewProjectDefaults.lastSettings(slot: slot) { doc.data.setSettings(s, slot: slot) }
            } else {
                var s = doc.data.settings(slot: slot)
                NewProjectDefaults.apply(choice, to: &s)
                doc.data.setSettings(s, slot: slot)
            }
        }
        return doc
    }
}

/// Picker of all built-in presets and own profiles, by id.
struct ProfileIDPicker: View {
    let title: LocalizedStringKey
    @Binding var id: String
    @ObservedObject private var store = ProfileStore.shared

    var body: some View {
        Picker(title, selection: $id) {
            Text("Last used").tag(NewProjectDefaults.lastUsed)
            Divider()
            ForEach(MaterialPreset.Category.allCases) { category in
                Section(category.title) {
                    ForEach(MaterialPreset.all.filter { $0.category == category }) { Text($0.title).tag($0.id) }
                }
            }
            if !store.profiles.isEmpty {
                Section("My profiles") {
                    ForEach(store.profiles) { Text(verbatim: $0.name).tag($0.settingsID) }
                }
            }
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @AppStorage(LengthUnit.storageKey) private var unit: LengthUnit = .mm
    @AppStorage(NewProjectDefaults.matKey) private var newMat = NewProjectDefaults.lastUsed
    @AppStorage(NewProjectDefaults.profile1Key) private var newProfile1 = NewProjectDefaults.lastUsed
    @AppStorage(NewProjectDefaults.profile2Key) private var newProfile2 = NewProjectDefaults.lastUsed
    @AppStorage(NewProjectDefaults.previewFirstKey) private var previewFirst = false
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
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { appearance.apply() }
                Picker("Unit", selection: $unit) {
                    ForEach(LengthUnit.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .tip("Unit for all lengths you type in. Projects keep their sizes.")
            }
            Section {
                Picker("Mat", selection: $newMat) {
                    Text("Last used").tag(NewProjectDefaults.lastUsed)
                    Divider()
                    ForEach(MatType.allCases) { Text($0.title).tag($0.rawValue) }
                }
                ProfileIDPicker(title: "Tool 1", id: $newProfile1)
                ProfileIDPicker(title: "Tool 2", id: $newProfile2)
            } header: {
                Text("New projects")
            } footer: {
                Text("“Last used” takes the mat and the tool values (with your changes) of the project you worked on last. Open projects keep their own settings.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show the preview before every cut", isOn: $previewFirst)
            } header: {
                Text("Cutting")
            } footer: {
                Text("You see the order of the lines and the time, and start the cut from there.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
