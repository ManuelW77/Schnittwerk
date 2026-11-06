// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// Cutting mat or roll in the Cameo 4.
enum MatType: String, Codable, CaseIterable, Identifiable {
    case mat12x12
    case mat12x24
    case roll

    var id: String { rawValue }

    /// Value for the GPGL command `TG`.
    var tgIndex: Int {
        switch self {
        case .roll: return 0
        case .mat12x12: return 1
        case .mat12x24: return 2
        }
    }

    /// Cutting area in mm (width × length).
    var size: CGSize {
        switch self {
        case .mat12x12: return CGSize(width: 304.8, height: 304.8)
        case .mat12x24: return CGSize(width: 304.8, height: 609.6)
        case .roll: return CGSize(width: 304.0, height: 3000.0)
        }
    }

    /// Height shown in the editor. A roll is shown 600 mm long.
    var displaySize: CGSize {
        self == .roll ? CGSize(width: size.width, height: 600) : size
    }

    var title: String {
        switch self {
        case .mat12x12: return String(localized: "Mat 12 × 12 in")
        case .mat12x24: return String(localized: "Mat 12 × 24 in")
        case .roll: return String(localized: "Without mat (roll)")
        }
    }
}

/// Tool in the tool holder.
enum ToolKind: String, Codable, CaseIterable, Identifiable {
    case autoBlade
    case ratchetBlade
    case pen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoBlade: return String(localized: "AutoBlade")
        case .ratchetBlade: return String(localized: "Ratchet blade")
        case .pen: return String(localized: "Pen")
        }
    }

    var isBlade: Bool { self != .pen }
}

/// All values the plotter needs for one cut.
struct CutSettings: Codable, Equatable {
    var tool: ToolKind = .autoBlade
    /// 1 = left holder, 2 = right holder.
    var holder: Int = 1
    /// Blade depth of the AutoBlade, 1–10.
    var depth: Int = 2
    /// Force, 1–33.
    var pressure: Int = 10
    /// Speed, 1–30.
    var speed: Int = 5
    /// How often each line is cut, 1–10.
    var passes: Int = 1
    /// Name of the material preset the values came from.
    var materialID: String? = MaterialPreset.vinyl.id

    static let pressureRange = 1...33
    static let speedRange = 1...30
    static let depthRange = 1...10
    static let passesRange = 1...10

    /// Values limited to what the plotter accepts.
    var clamped: CutSettings {
        var s = self
        s.holder = min(max(holder, 1), 2)
        s.depth = min(max(depth, Self.depthRange.lowerBound), Self.depthRange.upperBound)
        s.pressure = min(max(pressure, Self.pressureRange.lowerBound), Self.pressureRange.upperBound)
        s.speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        s.passes = min(max(passes, Self.passesRange.lowerBound), Self.passesRange.upperBound)
        return s
    }
}

/// Starting values for common materials. Always do a test cut first.
struct MaterialPreset: Identifiable, Equatable {
    let id: String
    let tool: ToolKind
    let depth: Int
    let pressure: Int
    let speed: Int
    let passes: Int

    var title: String {
        switch id {
        case "vinyl": return String(localized: "Vinyl (glossy/matte)")
        case "htv": return String(localized: "Heat transfer vinyl")
        case "paper": return String(localized: "Paper 80 g/m²")
        case "cardstock": return String(localized: "Cardstock 220 g/m²")
        case "sticker": return String(localized: "Sticker paper")
        case "pen": return String(localized: "Drawing with pen")
        default: return id
        }
    }

    func apply(to settings: inout CutSettings) {
        settings.tool = tool
        settings.depth = depth
        settings.pressure = pressure
        settings.speed = speed
        settings.passes = passes
        settings.materialID = id
    }

    static let vinyl = MaterialPreset(id: "vinyl", tool: .autoBlade, depth: 2, pressure: 10, speed: 5, passes: 1)
    static let htv = MaterialPreset(id: "htv", tool: .autoBlade, depth: 2, pressure: 9, speed: 5, passes: 1)
    static let paper = MaterialPreset(id: "paper", tool: .autoBlade, depth: 2, pressure: 12, speed: 5, passes: 1)
    static let cardstock = MaterialPreset(id: "cardstock", tool: .autoBlade, depth: 4, pressure: 24, speed: 3, passes: 2)
    static let sticker = MaterialPreset(id: "sticker", tool: .autoBlade, depth: 2, pressure: 14, speed: 5, passes: 1)
    static let pen = MaterialPreset(id: "pen", tool: .pen, depth: 1, pressure: 10, speed: 5, passes: 1)

    static let all: [MaterialPreset] = [.vinyl, .htv, .paper, .cardstock, .sticker, .pen]
}
