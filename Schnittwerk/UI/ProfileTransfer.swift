// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// `.schnittprofile`, declared in Info.plist.
    static let schnittwerkProfiles = UTType(exportedAs: "de.manuelweiser.schnittwerk.cutprofiles")
}

/// Save and open panels for exporting and importing cut profiles.
@MainActor
enum ProfileTransfer {
    /// Saves the profiles into one `.schnittprofile` file.
    static func export(_ profiles: [CutProfile], suggestedName: String) {
        guard !profiles.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.schnittwerkProfiles]
        panel.nameFieldStringValue = suggestedName
        panel.message = profiles.count == 1
            ? String(localized: "Export cut profile")
            : String(localized: "Export \(profiles.count) cut profiles")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProfileStore.shared.exportData(profiles).write(to: url, options: .atomic)
        } catch {
            showAlert(String(localized: "Export failed"), error.localizedDescription, style: .warning)
        }
    }

    static func exportAll() {
        export(ProfileStore.shared.profiles, suggestedName: String(localized: "Cut profiles") + ".schnittprofile")
    }

    /// Lets the user pick one or more files and adds their profiles.
    static func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.schnittwerkProfiles, .json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose one or more cut profile files")
        guard panel.runModal() == .OK else { return }

        var total = ProfileStore.ImportSummary()
        var errors: [String] = []
        for url in panel.urls {
            do {
                let data = try Data(contentsOf: url)
                let s = try ProfileStore.shared.importProfiles(from: data)
                total.added += s.added
                total.unchanged += s.unchanged
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        var lines = [String(localized: "Imported: \(total.added)")]
        if total.unchanged > 0 { lines.append(String(localized: "Already there: \(total.unchanged)")) }
        lines += errors
        showAlert(errors.isEmpty ? String(localized: "Cut profiles imported") : String(localized: "Import with errors"),
                  lines.joined(separator: "\n"), style: errors.isEmpty ? .informational : .warning)
    }

    static func fileName(for name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return (cleaned.isEmpty ? "Profil" : cleaned) + ".schnittprofile"
    }

    private static func showAlert(_ title: String, _ text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }
}
