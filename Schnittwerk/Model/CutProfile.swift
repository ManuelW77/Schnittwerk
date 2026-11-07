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
    var options = CutOptions()

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
        options = s.options
    }

    init(name: String, preset: MaterialPreset) {
        self.name = name
        tool = preset.tool
        depth = preset.depth
        pressure = preset.pressure
        speed = preset.speed
        passes = preset.passes
        options = preset.options
    }

    func apply(to settings: inout CutSettings) {
        settings.tool = tool
        settings.depth = depth
        settings.pressure = pressure
        settings.speed = speed
        settings.passes = passes
        settings.options = options
        settings.materialID = settingsID
    }

    /// True if the cut values equal this profile (holder is not part of a profile).
    func matches(_ s: CutSettings) -> Bool {
        s.tool == tool && s.pressure == pressure && s.speed == speed && s.passes == passes
            && (!tool.setsDepth || s.depth == depth) && s.options == options
    }

    private enum CodingKeys: String, CodingKey { case id, name, tool, depth, pressure, speed, passes, options }

    /// Missing id (hand-written files) gets a new one; missing depth/passes get defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        tool = try c.decode(ToolKind.self, forKey: .tool)
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 2
        pressure = try c.decode(Int.self, forKey: .pressure)
        speed = try c.decode(Int.self, forKey: .speed)
        passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? 1
        options = try c.decodeIfPresent(CutOptions.self, forKey: .options) ?? CutOptions()
    }

    var clamped: CutProfile {
        var p = self
        p.depth = min(max(depth, CutSettings.depthRange.lowerBound), CutSettings.depthRange.upperBound)
        p.pressure = min(max(pressure, CutSettings.pressureRange.lowerBound), CutSettings.pressureRange.upperBound)
        p.speed = min(max(speed, CutSettings.speedRange.lowerBound), CutSettings.speedRange.upperBound)
        p.passes = min(max(passes, CutSettings.passesRange.lowerBound), CutSettings.passesRange.upperBound)
        p.options = options.clamped
        return p
    }
}

extension MaterialPreset {
    func matches(_ s: CutSettings) -> Bool {
        s.tool == tool && s.pressure == pressure && s.speed == speed && s.passes == passes
            && (!tool.setsDepth || s.depth == depth) && s.options == options
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

    // MARK: - Import / export

    struct ImportSummary: Equatable {
        var added = 0
        /// Profiles that already exist with exactly the same values.
        var unchanged = 0
    }

    /// File content for export: one or many profiles, same format.
    func exportData(_ selection: [CutProfile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ProfileExportFile(profiles: selection))
    }

    /// Adds the profiles from an export file. Existing profiles are never
    /// overwritten: a profile with the same id but other values is added
    /// as a copy with its own name.
    @discardableResult
    func importProfiles(from data: Data) throws -> ImportSummary {
        let incoming = try ProfileExportFile.decode(data)
        var summary = ImportSummary()
        for var p in incoming {
            p = p.clamped
            if let existing = profiles.first(where: { $0.id == p.id }) {
                if existing == p || (existing.name == p.name && existing.matchesValues(p)) {
                    summary.unchanged += 1
                    continue
                }
                p.id = UUID()
            }
            p.name = uniqueName(p.name.trimmingCharacters(in: .whitespacesAndNewlines), excluding: nil)
            profiles.append(p)
            summary.added += 1
        }
        if summary.added > 0 { save() }
        return summary
    }
}

extension CutProfile {
    func matchesValues(_ other: CutProfile) -> Bool {
        tool == other.tool && depth == other.depth && pressure == other.pressure
            && speed == other.speed && passes == other.passes && options == other.options
    }
}

/// `.schnittprofile` file (JSON).
struct ProfileExportFile: Codable {
    var app = "Schnittwerk"
    var version = 1
    var profiles: [CutProfile]

    static let maxBytes = 2_000_000
    static let maxProfiles = 1000

    enum ImportError: LocalizedError {
        case tooLarge, notAProfileFile, empty

        var errorDescription: String? {
            switch self {
            case .tooLarge: return String(localized: "The file is too large for a cut profile file.")
            case .notAProfileFile: return String(localized: "The file does not contain Schnittwerk cut profiles.")
            case .empty: return String(localized: "The file contains no cut profiles.")
            }
        }
    }

    static func decode(_ data: Data) throws -> [CutProfile] {
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        // Also accepts the app's own profiles.json (same "profiles" array)
        guard let file = try? JSONDecoder().decode(ProfileExportFile.Loose.self, from: data) else {
            throw ImportError.notAProfileFile
        }
        let list = Array(file.profiles.prefix(maxProfiles))
        guard !list.isEmpty else { throw ImportError.empty }
        return list
    }

    /// Like the file, but "app" and "version" may be missing.
    private struct Loose: Decodable {
        var profiles: [CutProfile]
    }
}
