// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Menu to choose a built-in preset or an own cut profile, grouped by
// material. A menu with buttons instead of a Picker: a Picker with
// sections showed the section name instead of the chosen profile.

import SwiftUI

struct ProfileMenu: View {
    let title: LocalizedStringKey
    /// Preset id, own profile id ("user:…"), or "last" / "custom".
    @Binding var selection: String
    /// Offers "Last used" (for new projects).
    var allowLast = false
    /// Shows "Custom" as the current value (values changed by hand).
    var showCustom = false
    @ObservedObject private var store = ProfileStore.shared

    private var currentTitle: String {
        if allowLast, selection == NewProjectDefaults.lastUsed { return String(localized: "Last used") }
        if let p = MaterialPreset.all.first(where: { $0.id == selection }) { return p.title }
        if let p = store.profile(settingsID: selection) { return p.name }
        return String(localized: "Custom")
    }

    private func item(_ label: String, id: String) -> some View {
        Button {
            selection = id
        } label: {
            if selection == id { Label(label, systemImage: "checkmark") } else { Text(verbatim: label) }
        }
    }

    var body: some View {
        LabeledContent(title) {
            Menu {
                if allowLast {
                    item(String(localized: "Last used"), id: NewProjectDefaults.lastUsed)
                    Divider()
                }
                ForEach(MaterialPreset.Category.allCases) { category in
                    Section(category.title) {
                        ForEach(MaterialPreset.all.filter { $0.category == category }) { item($0.title, id: $0.id) }
                    }
                }
                if !store.profiles.isEmpty {
                    Section("My profiles") {
                        ForEach(store.profiles) { item($0.name, id: $0.settingsID) }
                    }
                }
                if showCustom {
                    Divider()
                    item(String(localized: "Custom"), id: "custom")
                }
            } label: {
                HStack(spacing: 5) {
                    Text(verbatim: currentTitle)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(Text(title))
        }
    }
}
