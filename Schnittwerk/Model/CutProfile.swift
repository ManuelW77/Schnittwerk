// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Own cut profiles (material + values), saved for the whole app in
// ~/Library/Application Support/Schnittwerk/profiles.json.
// The built-in presets (MaterialPreset) stay read-only.

import Foundation

struct CutProfile: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var tool: ToolKind
    var depth: Int
    var pressure: Int
    var speed: Int
    var passes: Int

    /// Value stored in CutSettings.materialID.
    var settingsID: String { Self.prefix + id.uuidString }
    static let prefix = "user:"

    init(name: String, settings: CutSettings) {
        let s = settings.clamped
        self.name = name
        tool = s.tool
        depth = s.depth
        pressure = s.pressure
        speed = s.speed
        passes = s.passes
    }

    init(name: String, preset: MaterialPreset) {
        self.name = name
        tool = preset.tool
        depth = preset.depth
        pressure = preset.pressure
        speed = preset.speed
        passes = preset.passes
    }

    func apply(to settings: inout CutSettings) {
        settings.tool = tool
        settings.depth = depth
        settings.pressure = pressure
        settings.speed = speed
        settings.passes = passes
        settings.materialID = settingsID
    }

    /// True if the cut values equal this profile (holder is not part of a profile).
    func matches(_ s: CutSettings) -> Bool {
        s.tool == tool && s.pressure == pressure && s.speed == speed && s.passes == passes
            && (tool != .autoBlade || s.depth == depth)
    }

    var clamped: CutProfile {
        var p = self
        p.depth = min(max(depth, CutSettings.depthRange.lowerBound), CutSettings.depthRange.upperBound)
        p.pressure = min(max(pressure, CutSettings.pressureRange.lowerBound), CutSettings.pressureRange.upperBound)
        p.speed = min(max(speed, CutSettings.speedRange.lowerBound), CutSettings.speedRange.upperBound)
        p.passes = min(max(passes, CutSettings.passesRange.lowerBound), CutSettings.passesRange.upperBound)
        return p
    }
}

extension MaterialPreset {
    func matches(_ s: CutSettings) -> Bool {
        s.tool == tool && s.pressure == pressure && s.speed == speed && s.passes == passes
            && (tool != .autoBlade || s.depth == depth)
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore(fileURL: ProfileStore.defaultURL)

    @Published private(set) var profiles: [CutProfile] = []
    /// Last save/load problem, shown in the UI.
    @Published var lastError: String?

    let fileURL: URL

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Schnittwerk", isDirectory: true).appendingPathComponent("profiles.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Lookup

    func profile(settingsID: String?) -> CutProfile? {
        guard let settingsID, settingsID.hasPrefix(CutProfile.prefix),
              let uuid = UUID(uuidString: String(settingsID.dropFirst(CutProfile.prefix.count))) else { return nil }
        return profiles.first { $0.id == uuid }
    }

    // MARK: - Changes

    @discardableResult
    func add(_ profile: CutProfile) -> CutProfile {
        var p = profile.clamped
        p.name = uniqueName(p.name.trimmingCharacters(in: .whitespacesAndNewlines), excluding: nil)
        profiles.append(p)
        save()
        return p
    }

    func update(_ profile: CutProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var p = profile.clamped
        let trimmed = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.name = trimmed.isEmpty ? profiles[i].name : trimmed
        guard profiles[i] != p else { return }
        profiles[i] = p
        save()
    }

    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
    }

    /// "Vinyl", "Vinyl 2", … so names stay unique in the picker.
    func uniqueName(_ name: String, excluding id: UUID?) -> String {
        let base = name.isEmpty ? String(localized: "New profile") : name
        let taken = Set(profiles.filter { $0.id != id }.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - File

    private struct FileContent: Codable {
        var version = 1
        var profiles: [CutProfile]
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { profiles = []; return }
        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try JSONDecoder().decode(FileContent.self, from: data).profiles.map(\.clamped)
            lastError = nil
        } catch {
            // Keep the broken file; it is only replaced on the next save
            profiles = []
            lastError = String(localized: "Your cut profiles could not be loaded: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(FileContent(profiles: profiles)).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = String(localized: "Your cut profiles could not be saved: \(error.localizedDescription)")
        }
    }
}
