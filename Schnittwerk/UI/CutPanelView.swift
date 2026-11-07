// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Cut settings, material presets and sending to the plotter.
struct CutPanelView: View {
    @ObservedObject var document: CutDocument
    @ObservedObject private var plotter = PlotterController.shared
    @Environment(\.undoManager) private var undoManager
    @ObservedObject private var store = ProfileStore.shared
    @State private var confirmOutside = false
    @State private var askNewName = false
    @State private var newName = ""
    @State private var askRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @AppStorage(ConnectionKind.storageKey) private var connection: ConnectionKind = .automatic
    /// Tool whose values are shown: 1 or 2.
    @Binding var slot: Int

    private var settings: CutSettings { document.data.settings(slot: slot) }

    /// Changes the values; the chosen profile stays selected and is
    /// shown as "changed" until it is saved or reset.
    private func set(_ edit: @escaping (inout CutSettings) -> Void) {
        let slot = slot
        document.update(String(localized: "Change cut settings"), undoManager: undoManager) { data in
            var s = data.settings(slot: slot)
            edit(&s)
            data.setSettings(s, slot: slot)
        }
    }

    private var builtIn: MaterialPreset? { MaterialPreset.all.first { $0.id == settings.materialID } }
    private var ownProfile: CutProfile? { store.profile(settingsID: settings.materialID) }

    private var pickerValue: String {
        if builtIn != nil || ownProfile != nil { return settings.materialID ?? "custom" }
        return "custom"
    }

    private var isModified: Bool {
        if let p = ownProfile { return !p.matches(settings) }
        if let p = builtIn { return !p.matches(settings) }
        return false
    }

    private func select(_ id: String) {
        if let p = MaterialPreset.all.first(where: { $0.id == id }) {
            set { p.apply(to: &$0) }
        } else if let p = store.profile(settingsID: id) {
            set { p.apply(to: &$0) }
        }
    }

    /// The selected profile with the current values (for export).
    private var currentAsProfile: CutProfile {
        let name = ownProfile?.name ?? builtIn?.title ?? String(localized: "Custom")
        var p = CutProfile(name: name, settings: settings)
        if let own = ownProfile, !isModified { p.id = own.id } // same id: re-import is recognised
        return p
    }

    private func saveAsNewProfile() {
        let suggested = ownProfile?.name ?? builtIn?.title ?? String(localized: "New profile")
        let profile = store.add(CutProfile(name: newName.isEmpty ? suggested : newName, settings: settings))
        set { $0.materialID = profile.settingsID }
    }

    private func intBinding(_ keyPath: WritableKeyPath<CutSettings, Int>) -> Binding<Int> {
        Binding(get: { settings[keyPath: keyPath] }, set: { v in set { $0[keyPath: keyPath] = v } })
    }

    private func optionBinding<V>(_ keyPath: WritableKeyPath<CutOptions, V>) -> Binding<V> {
        Binding(get: { settings.options[keyPath: keyPath] }, set: { v in set { $0.options[keyPath: keyPath] = v } })
    }

    private var offsetText: String {
        let mm = Double(settings.options.offsetAdjust) * 0.05
        return mm == 0 ? "0" : String(format: "%+.2f mm", mm)
    }

    private var outsideCount: Int {
        let area = document.data.mat.size
        return document.data.shapes.filter { $0.cutEnabled && !$0.fits(in: area) }.count
    }

    private var cutCount: Int { document.data.shapes.filter(\.cutEnabled).count }

    private func objectCount(_ slot: Int) -> Int {
        document.data.shapes.filter { $0.cutEnabled && $0.toolSlot == slot }.count
    }

    /// Problems of the chosen tool in this holder, or nil.
    private var holderWarning: String? {
        guard let needed = settings.tool.requiredHolder, needed != slot else { return nil }
        return String(localized: "\(settings.tool.title) only fits into holder \(needed) (Cameo 4 line). Choose it for tool \(needed) instead.")
    }

    var body: some View {
        Form {
            Section {
                Picker("Tool", selection: $slot) {
                    ForEach([1, 2], id: \.self) { n in
                        Text(verbatim: "\(ToolSlotStyle.title(n)) (\(objectCount(n)))").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 8) {
                    ToolSlotBadge(slot: slot)
                    Text(slot == 1 ? "Left holder" : "Right holder")
                    Spacer()
                    Image(systemName: settings.tool.systemImage)
                        .foregroundStyle(ToolSlotStyle.color(slot))
                    Text(verbatim: settings.tool.title)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Text("Objects shown in this colour are cut with this tool. Choose the tool of an object in the Object panel or with a right click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cut profile") {
                Picker("Profile", selection: Binding(get: { pickerValue }, set: select)) {
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
                    if pickerValue == "custom" {
                        Text("Custom").tag("custom")
                    }
                }

                if isModified {
                    HStack {
                        Label("Changed", systemImage: "pencil")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Reset") { select(pickerValue) }
                        if let p = ownProfile {
                            Button("Save to profile") {
                                var updated = CutProfile(name: p.name, settings: settings)
                                updated.id = p.id
                                store.update(updated)
                            }
                            .help("Saves the current values into “\(p.name)”")
                        }
                    }
                }

                HStack {
                    Button("Save as new profile…") {
                        newName = ""
                        askNewName = true
                    }
                    Spacer()
                    Menu {
                        if let p = ownProfile {
                            Button("Rename…") {
                                renameText = p.name
                                askRename = true
                            }
                            Button("Delete…", role: .destructive) { confirmDelete = true }
                            Divider()
                        }
                        Button("Export this profile…") {
                            let profile = currentAsProfile
                            ProfileTransfer.export([profile], suggestedName: ProfileTransfer.fileName(for: profile.name))
                        }
                        Button("Export all own profiles…") { ProfileTransfer.exportAll() }
                            .disabled(store.profiles.isEmpty)
                        Button("Import profiles…") { ProfileTransfer.importFiles() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Rename, delete, import or export profiles")
                    SettingsLink {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .help("Manage all cut profiles")
                }

                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Text("Built-in values are starting points. Always do a test cut on new material.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tool") {
                Picker("Tool", selection: Binding(get: { settings.tool }, set: { t in set { $0.tool = t } })) {
                    ForEach(ToolKind.allCases) { Text($0.title).tag($0) }
                }
                if let holderWarning {
                    Label(holderWarning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if settings.tool.setsDepth {
                    Stepper(value: intBinding(\.depth), in: CutSettings.depthRange) {
                        LabeledContent("Blade depth", value: "\(settings.depth)")
                    }
                }
                Stepper(value: intBinding(\.pressure), in: CutSettings.pressureRange) {
                    LabeledContent("Force", value: "\(settings.pressure)")
                }
                Stepper(value: intBinding(\.speed), in: CutSettings.speedRange) {
                    LabeledContent("Speed", value: "\(settings.speed)")
                }
                Stepper(value: intBinding(\.passes), in: CutSettings.passesRange) {
                    LabeledContent("Passes", value: "\(settings.passes)")
                }
            }

            Section("Cut options") {
                Stepper(value: optionBinding(\.acceleration), in: CutOptions.accelerationRange) {
                    LabeledContent("Acceleration", value: "\(settings.options.acceleration)")
                }
                .help("Lower values move the head more gently, e.g. for thick or delicate material. Cameo 4 line only.")
                if settings.tool.isBlade {
                    Stepper(value: optionBinding(\.offsetAdjust), in: CutOptions.offsetAdjustRange) {
                        LabeledContent("Blade offset", value: offsetText)
                    }
                    .help("Correction of the blade tip offset in 0.05 mm steps. Raise it if corners come out round.")
                    Toggle("Overcut", isOn: optionBinding(\.overcut))
                        .help("Closed lines are cut 1 mm past their start, so the piece comes out cleanly")
                    Toggle("Sharp corners (Smart Cut)", isOn: optionBinding(\.sharpCorners))
                        .help("At sharp corners the blade runs a little past the corner and starts again, for crisp corners in thick material")
                }
                Toggle("Track enhancing", isOn: optionBinding(\.trackEnhancing))
                    .help("The plotter rolls the mat in and out a few times first, so the rollers grip better (e.g. for long or thick material)")
            }

            Section("Plotter") {
                Picker("Connection", selection: $connection) {
                    ForEach(ConnectionKind.allCases) { Text($0.title).tag($0) }
                }
                .disabled(plotter.isBusy)
                .help("Automatic tries USB first, then Bluetooth. Supported: \(PlotterModel.supportedNames). Bluetooth: Cameo 3, Cameo 4, 4 Plus and 4 Pro. Cameo 3 and older machines cut at speed 10 at most.")
                statusView
                if let p = plotter.progress {
                    ProgressView(value: p)
                }
                if outsideCount > 0 {
                    Label("Outside the cutting area: \(outsideCount). The parts outside are not cut, to protect the mat.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if plotter.isBusy {
                    Button("Cancel", role: .cancel) { plotter.cancel() }
                } else {
                    Button {
                        if outsideCount > 0 { confirmOutside = true } else { cut() }
                    } label: {
                        Label("Cut (\(cutCount))", systemImage: "scissors")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(cutCount == 0)
                    .keyboardShortcut(.return, modifiers: .command)

                    HStack {
                        Button("Test cut") {
                            let settings = settings, mat = document.data.mat // the tool shown
                            plotter.send { GPGLBuilder.testCut(settings: settings, mat: mat, model: $0) }
                        }
                        .help("Cuts a 10 mm square with a triangle at the top left of the mat")
                        Button("Check connection") { plotter.checkConnection() }
                    }
                    Button("Export commands…", action: exportCommands)
                        .help("Saves the plotter commands as a text file, to check them without a plotter")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Some objects lie outside the cutting area.", isPresented: $confirmOutside) {
            Button("Cut anyway") { cut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The parts outside the cutting area are left out, so the blade does not cut into the mat.")
        }
        .alert("Save as new profile", isPresented: $askNewName) {
            TextField("Name", text: $newName)
            Button("Save", action: saveAsNewProfile)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves tool, blade depth, force, speed, passes and cut options.")
        }
        .alert("Rename profile", isPresented: $askRename) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                guard var p = ownProfile else { return }
                p.name = store.uniqueName(renameText.trimmingCharacters(in: .whitespaces), excluding: p.id)
                store.update(p)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete the profile “\(ownProfile?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                guard let p = ownProfile else { return }
                store.delete(id: p.id)
                // The values stay; the project just no longer points to the profile
                set { $0.materialID = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Projects that use it keep their values.")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch plotter.phase {
        case .idle:
            Text("Close Silhouette Studio, load the mat, then cut.")
                .foregroundStyle(.secondary)
        case .working(let text):
            Label(text, systemImage: "hourglass")
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func cut() {
        let data = document.data
        plotter.send { GPGLBuilder.build(for: data, model: $0) }
    }

    private func exportCommands() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Schnittwerk-GPGL.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? GPGLBuilder.build(for: document.data, model: plotter.lastModel).text.write(to: url, atomically: true, encoding: .utf8)
    }
}
