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
    /// Deep cut blade for leather, felt and chipboard (Cameo 4: holder 2).
    case kraftBlade
    case pen
    /// Embossing tool: presses lines into paper or foil without cutting.
    case emboss
    /// Punch tool: pierces single dots (stippling).
    case punch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoBlade: return String(localized: "AutoBlade")
        case .ratchetBlade: return String(localized: "Ratchet blade")
        case .kraftBlade: return String(localized: "Kraft Blade (leather)")
        case .pen: return String(localized: "Pen")
        case .emboss: return String(localized: "Embossing tool")
        case .punch: return String(localized: "Punch tool")
        }
    }

    var systemImage: String {
        switch self {
        case .autoBlade, .ratchetBlade: return "scissors"
        case .kraftBlade: return "scissors.badge.ellipsis"
        case .pen: return "pencil.tip"
        case .emboss: return "seal"
        case .punch: return "circle.dotted"
        }
    }

    /// Tools with a blade tip that trails behind the axis (blade offset).
    var isBlade: Bool { self == .autoBlade || self == .ratchetBlade || self == .kraftBlade }

    /// Tools that set their blade depth themselves (command `TF`).
    var setsDepth: Bool { self == .autoBlade || self == .kraftBlade }

    /// Holder the tool fits into on the Cameo 4 line, nil = both.
    var requiredHolder: Int? {
        switch self {
        case .autoBlade: return 1
        case .kraftBlade, .punch: return 2
        default: return nil
        }
    }
}

/// Extra cut options, as in Silhouette Studio.
struct CutOptions: Codable, Equatable, Hashable {
    /// Acceleration 1 (gentle) to 3 (fast). Cameo 4 line only.
    var acceleration: Int = 3
    /// Correction of the blade offset in 0.05 mm steps, −10…10.
    var offsetAdjust: Int = 0
    /// Closed lines are cut a bit past their start, so nothing stays attached.
    var overcut: Bool = false
    /// The plotter rolls the mat in and out first, so the rollers leave a track.
    var trackEnhancing: Bool = false
    /// Sharp corners: the blade runs past the corner and starts again ("Smart Cut").
    var sharpCorners: Bool = false

    static let accelerationRange = 1...3
    static let offsetAdjustRange = -10...10
    /// How far an overcut runs past the start (mm).
    static let overcutMM: CGFloat = 1
    /// How far the blade runs past a sharp corner (mm).
    static let cornerOvershootMM: CGFloat = 0.4
    /// Turning angle (degrees) from which a corner counts as sharp.
    static let sharpCornerAngle: CGFloat = 60

    var clamped: CutOptions {
        var o = self
        o.acceleration = min(max(acceleration, Self.accelerationRange.lowerBound), Self.accelerationRange.upperBound)
        o.offsetAdjust = min(max(offsetAdjust, Self.offsetAdjustRange.lowerBound), Self.offsetAdjustRange.upperBound)
        return o
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        acceleration = try c.decodeIfPresent(Int.self, forKey: .acceleration) ?? 3
        offsetAdjust = try c.decodeIfPresent(Int.self, forKey: .offsetAdjust) ?? 0
        overcut = try c.decodeIfPresent(Bool.self, forKey: .overcut) ?? false
        trackEnhancing = try c.decodeIfPresent(Bool.self, forKey: .trackEnhancing) ?? false
        sharpCorners = try c.decodeIfPresent(Bool.self, forKey: .sharpCorners) ?? false
    }
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
    var options = CutOptions()

    static let pressureRange = 1...33
    static let speedRange = 1...30
    static let depthRange = 1...10
    static let passesRange = 1...10

    init() {}

    /// Default for holder 2: a pen, which fits into both holders.
    static var holder2Default: CutSettings {
        var s = CutSettings()
        MaterialPreset.pen.apply(to: &s)
        s.holder = 2
        return s
    }

    /// Values limited to what the plotter accepts.
    var clamped: CutSettings {
        var s = self
        s.holder = min(max(holder, 1), 2)
        s.depth = min(max(depth, Self.depthRange.lowerBound), Self.depthRange.upperBound)
        s.pressure = min(max(pressure, Self.pressureRange.lowerBound), Self.pressureRange.upperBound)
        s.speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        s.passes = min(max(passes, Self.passesRange.lowerBound), Self.passesRange.upperBound)
        s.options = options.clamped
        return s
    }

    /// Older project files have no options yet.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decodeIfPresent(ToolKind.self, forKey: .tool) ?? .autoBlade
        holder = try c.decodeIfPresent(Int.self, forKey: .holder) ?? 1
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 2
        pressure = try c.decodeIfPresent(Int.self, forKey: .pressure) ?? 10
        speed = try c.decodeIfPresent(Int.self, forKey: .speed) ?? 5
        passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? 1
        materialID = try c.decodeIfPresent(String.self, forKey: .materialID)
        options = try c.decodeIfPresent(CutOptions.self, forKey: .options) ?? CutOptions()
    }
}

/// Starting values for common materials. Always do a test cut first.
/// Many values come from the table of michamade.de/schnitteinstellungen
/// (Cameo 4, AutoBlade); the Kraft Blade values follow Silhouette's
/// own starting points.
struct MaterialPreset: Identifiable, Equatable {
    enum Category: String, CaseIterable, Identifiable {
        case vinyl, htv, paper, cardstock, leather, tools
        var id: String { rawValue }
        var title: String {
            switch self {
            case .vinyl: return String(localized: "Adhesive vinyl")
            case .htv: return String(localized: "Heat transfer vinyl")
            case .paper: return String(localized: "Paper")
            case .cardstock: return String(localized: "Cardstock")
            case .leather: return String(localized: "Leather and thick material")
            case .tools: return String(localized: "Pen, embossing, punching")
            }
        }
    }

    let id: String
    let category: Category
    private let titleKey: String.LocalizationValue
    let tool: ToolKind
    let depth: Int
    let pressure: Int
    let speed: Int
    let passes: Int
    var options = CutOptions()

    init(_ id: String, _ category: Category, _ title: String.LocalizationValue, tool: ToolKind = .autoBlade,
         depth: Int, pressure: Int, speed: Int, passes: Int = 1, overcut: Bool = false) {
        self.id = id
        self.category = category
        self.titleKey = title
        self.tool = tool
        self.depth = depth
        self.pressure = pressure
        self.speed = speed
        self.passes = passes
        options.overcut = overcut
    }

    var title: String { String(localized: titleKey) }

    static func == (a: MaterialPreset, b: MaterialPreset) -> Bool { a.id == b.id }

    func apply(to settings: inout CutSettings) {
        settings.tool = tool
        settings.depth = depth
        settings.pressure = pressure
        settings.speed = speed
        settings.passes = passes
        settings.options = options
        settings.materialID = id
    }

    // The first six ids are kept: older projects point to them.
    static let vinyl = MaterialPreset("vinyl", .vinyl, "Vinyl (glossy/matte)", depth: 2, pressure: 10, speed: 5)
    static let htv = MaterialPreset("htv", .htv, "Heat transfer vinyl", depth: 2, pressure: 9, speed: 5)
    static let paper = MaterialPreset("paper", .paper, "Paper 80 g/m²", depth: 2, pressure: 12, speed: 5)
    static let cardstock = MaterialPreset("cardstock", .cardstock, "Cardstock 220 g/m²", depth: 4, pressure: 24, speed: 3, passes: 2)
    static let sticker = MaterialPreset("sticker", .paper, "Sticker paper", depth: 2, pressure: 14, speed: 5)
    static let pen = MaterialPreset("pen", .tools, "Drawing with pen", tool: .pen, depth: 1, pressure: 10, speed: 5)

    static let all: [MaterialPreset] = [
        // Adhesive vinyl
        vinyl,
        MaterialPreset("oracal631", .vinyl, "Oracal 631 (matte)", depth: 1, pressure: 10, speed: 2, passes: 2),
        MaterialPreset("oracal651", .vinyl, "Oracal 531/651 (glossy)", depth: 2, pressure: 15, speed: 1),
        MaterialPreset("dcfix", .vinyl, "d-c-fix adhesive film", depth: 1, pressure: 25, speed: 8, passes: 2),
        MaterialPreset("frosted", .vinyl, "Frosted glass film", depth: 4, pressure: 25, speed: 5),
        // Heat transfer vinyl
        htv,
        MaterialPreset("htvTextile", .htv, "Textile vinyl (white, matte)", depth: 2, pressure: 12, speed: 8),
        MaterialPreset("poliflex", .htv, "Poliflex Premium", depth: 2, pressure: 8, speed: 5),
        MaterialPreset("siserPS", .htv, "Siser P.S. Electric", depth: 2, pressure: 8, speed: 5),
        MaterialPreset("easyflex", .htv, "Oiss Easy Flex", depth: 2, pressure: 4, speed: 4),
        MaterialPreset("htvMetallic", .htv, "Metallic HTV (Stahls)", depth: 3, pressure: 19, speed: 5),
        MaterialPreset("schillerFlex", .htv, "Schiller Flex", depth: 3, pressure: 8, speed: 7),
        // Paper
        paper,
        sticker,
        MaterialPreset("photo", .paper, "Photo paper 100 g/m²", depth: 2, pressure: 15, speed: 10),
        MaterialPreset("vellumCut", .paper, "Vellum 110 g/m² (cut)", depth: 2, pressure: 25, speed: 10),
        MaterialPreset("vellumScore", .paper, "Vellum 110 g/m² (score)", depth: 1, pressure: 1, speed: 10),
        // Cardstock
        MaterialPreset("card200", .cardstock, "Cardstock 200 g/m²", depth: 3, pressure: 30, speed: 3),
        cardstock,
        MaterialPreset("luxuryCard", .cardstock, "Luxury cardstock 220 g/m²", depth: 3, pressure: 30, speed: 3),
        MaterialPreset("kraftPaperCut", .cardstock, "Kraft paper 260 g/m² (cut)", depth: 5, pressure: 33, speed: 3, passes: 2),
        MaterialPreset("kraftPaperScore", .cardstock, "Kraft paper 260 g/m² (score)", depth: 1, pressure: 20, speed: 1),
        MaterialPreset("snappap", .cardstock, "SnapPap (washable paper)", depth: 8, pressure: 33, speed: 3),
        // Leather and thick material
        MaterialPreset("fauxLeather", .leather, "Faux leather, smooth", depth: 7, pressure: 33, speed: 3, passes: 2, overcut: true),
        MaterialPreset("leatherThin", .leather, "Leather up to 1 mm (Kraft Blade)", tool: .kraftBlade,
                       depth: 6, pressure: 33, speed: 2, passes: 3, overcut: true),
        MaterialPreset("leatherThick", .leather, "Leather 1–2 mm (Kraft Blade)", tool: .kraftBlade,
                       depth: 10, pressure: 33, speed: 1, passes: 5, overcut: true),
        MaterialPreset("felt", .leather, "Felt (Kraft Blade)", tool: .kraftBlade, depth: 8, pressure: 30, speed: 3, passes: 2, overcut: true),
        MaterialPreset("chipboard", .leather, "Chipboard 1 mm (Kraft Blade)", tool: .kraftBlade,
                       depth: 10, pressure: 33, speed: 1, passes: 4, overcut: true),
        // Pen, embossing, punching
        pen,
        MaterialPreset("embossPaper", .tools, "Embossing paper", tool: .emboss, depth: 1, pressure: 20, speed: 3),
        MaterialPreset("embossFoil", .tools, "Embossing metal foil", tool: .emboss, depth: 1, pressure: 25, speed: 2),
        MaterialPreset("punchPaper", .tools, "Punching paper (stipple)", tool: .punch, depth: 1, pressure: 20, speed: 3),
    ]
}
