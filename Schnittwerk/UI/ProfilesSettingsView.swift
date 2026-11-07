// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Settings window (⌘,): create, edit and delete own cut profiles.
struct ProfilesSettingsView: View {
    @ObservedObject private var store = ProfileStore.shared
    @State private var selection: UUID?
    @State private var confirmDelete = false

    private var index: Int? {
        guard let selection else { return nil }
        return store.profiles.firstIndex { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.profiles) { p in
                        Text(verbatim: p.name).tag(p.id)
                    }
                }
                .overlay {
                    if store.profiles.isEmpty {
                        Text("No own profiles yet")
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Menu {
                        Button("Empty profile") { add(CutProfile(name: String(localized: "New profile"), settings: CutSettings())) }
                        Section("Copy of built-in") {
                            ForEach(MaterialPreset.all) { preset in
                                Button(preset.title) { add(CutProfile(name: preset.title, preset: preset)) }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .tip("New profile")

                    Button {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == nil)
                    .tip("Delete profile")
                    Spacer()
                    Menu {
                        Button("Import profiles…") { ProfileTransfer.importFiles() }
                        Divider()
                        Button("Export selected profile…") {
                            if let i = index {
                                let p = store.profiles[i]
                                ProfileTransfer.export([p], suggestedName: ProfileTransfer.fileName(for: p.name))
                            }
                        }
                        .disabled(index == nil)
                        Button("Export all profiles…") { ProfileTransfer.exportAll() }
                            .disabled(store.profiles.isEmpty)
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .tip("Import or export cut profiles")
                }
                .padding(6)
            }
            .frame(width: 200)

            Divider()

            Group {
                if let i = index {
                    editor(i)
                } else {
                    Text("Select a profile or create one with +.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 340)
        }
        .frame(width: 600, height: 400)
        .confirmationDialog("Delete the profile “\(index.map { store.profiles[$0].name } ?? "")”?",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let selection { store.delete(id: selection) }
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Projects that use it keep their values.")
        }
        .onAppear { if selection == nil { selection = store.profiles.first?.id } }
    }

    private func add(_ profile: CutProfile) {
        selection = store.add(profile).id
    }

    private func binding<T>(_ i: Int, _ keyPath: WritableKeyPath<CutProfile, T>) -> Binding<T> {
        Binding(
            get: { store.profiles[i][keyPath: keyPath] },
            set: { value in
                var p = store.profiles[i]
                p[keyPath: keyPath] = value
                store.update(p)
            }
        )
    }

    @ViewBuilder
    private func editor(_ i: Int) -> some View {
        let p = store.profiles[i]
        Form {
            ProfileNameField(profile: p)
                .id(p.id)
            Picker("Tool", selection: binding(i, \.tool)) {
                ForEach(ToolKind.allCases) { Text($0.title).tag($0) }
            }
            if p.tool == .autoBlade {
                Stepper(value: binding(i, \.depth), in: CutSettings.depthRange) {
                    LabeledContent("Blade depth", value: "\(p.depth)")
                }
            }
            Stepper(value: binding(i, \.pressure), in: CutSettings.pressureRange) {
                LabeledContent("Force", value: "\(p.pressure)")
            }
            Stepper(value: binding(i, \.speed), in: CutSettings.speedRange) {
                LabeledContent("Speed", value: "\(p.speed)")
            }
            Stepper(value: binding(i, \.passes), in: CutSettings.passesRange) {
                LabeledContent("Passes", value: "\(p.passes)")
            }
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Text("Changes are saved right away. Open projects keep their values until you pick the profile again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Name is saved on Return or when the field loses focus, so the
/// duplicate check does not change the name while typing.
private struct ProfileNameField: View {
    let profile: CutProfile
    @ObservedObject private var store = ProfileStore.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .focused($focused)
            .onAppear { text = profile.name }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var p = store.profiles.first(where: { $0.id == profile.id }) else { return }
        guard !trimmed.isEmpty, trimmed != p.name else { text = p.name; return }
        p.name = store.uniqueName(trimmed, excluding: p.id)
        store.update(p)
        text = p.name
    }
}
