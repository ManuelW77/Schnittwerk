// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// The tools an AI can call through MCP. They work on the project window
// that was in front last. Every change is one undo step (⌘Z).
// Sending to the plotter is deliberately not offered.
//
// Texts in this file are read by the AI, not by the user, so they stay
// in English and are not translated.

import CoreGraphics
import Foundation

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Typed access to the arguments of a tool call.
struct ToolArgs {
    let raw: [String: Any]

    func has(_ key: String) -> Bool { raw[key] != nil && !(raw[key] is NSNull) }

    func string(_ key: String) throws -> String? {
        guard has(key) else { return nil }
        guard let s = raw[key] as? String else { throw ToolError("“\(key)” must be a string.") }
        return s
    }

    func requiredString(_ key: String) throws -> String {
        guard let s = try string(key) else { throw ToolError("“\(key)” is required.") }
        return s
    }

    func double(_ key: String) throws -> Double? {
        guard has(key) else { return nil }
        // JSON numbers arrive as NSNumber; reject booleans and non-finite values
        guard let n = raw[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
            throw ToolError("“\(key)” must be a number.")
        }
        return n.doubleValue
    }

    func int(_ key: String) throws -> Int? {
        guard let d = try double(key) else { return nil }
        // Int(1e300) would crash; no tool needs more than this
        guard abs(d) <= 1_000_000 else { throw ToolError("“\(key)” is too large.") }
        return Int(d.rounded())
    }

    func bool(_ key: String) throws -> Bool? {
        guard has(key) else { return nil }
        guard let n = raw[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw ToolError("“\(key)” must be true or false.")
        }
        return n.boolValue
    }

    func strings(_ key: String) throws -> [String]? {
        guard has(key) else { return nil }
        if let s = raw[key] as? String { return [s] }
        guard let a = raw[key] as? [Any] else { throw ToolError("“\(key)” must be a list of strings.") }
        return try a.map {
            if let s = $0 as? String { return s }
            if let n = $0 as? NSNumber { return n.stringValue }
            throw ToolError("“\(key)” must be a list of strings.")
        }
    }
}

struct MCPTool {
    let name: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    /// Changes the project (false for tools that only read).
    let changes: Bool
    let run: (ToolArgs, DocumentContext) throws -> [[String: Any]]

    var definition: [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }
}

@MainActor
enum MCPTools {
    static let instructions = """
    Schnittwerk designs cut files for Silhouette cutting plotters (Cameo 4 line). \
    All lengths are millimetres. The origin is the top left corner of the mat, \
    x grows to the right and y grows downwards. x/y of an object is the top left \
    corner of its bounding box on the mat. Every object is a set of cut lines; \
    only outlines matter, there are no colours or fills. Closed lines inside \
    other closed lines become holes. Start with get_document, check your work \
    with render_preview. Objects can be referenced by id or by number (\"#3\"). \
    The tools work on the Schnittwerk window that was in front last. Every \
    change can be undone in the app with ⌘Z. Cutting is only started by the \
    user in the app.
    """

    static func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

    static func json(_ value: Any) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return text(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Describing objects

    /// Rounded to 0.01 mm. NSDecimalNumber, so JSON shows 112.71
    /// instead of 112.70999999999999.
    static func r(_ v: CGFloat) -> NSDecimalNumber {
        NSDecimalNumber(decimal: Decimal((Double(v) * 100).rounded()) / 100)
    }

    static func describe(_ shape: CutShape, number: Int, mat: MatType) -> [String: Any] {
        let b = shape.matBounds
        var d: [String: Any] = [
            "number": "#\(number)",
            "id": shape.id.uuidString,
            "name": shape.name,
            "x": r(b.minX), "y": r(b.minY),
            "bounds_width": r(b.width), "bounds_height": r(b.height),
            "width": r(shape.size.width), "height": r(shape.size.height),
            "rotation": r(shape.rotation),
            "mirrored_horizontally": shape.scaleX < 0,
            "mirrored_vertically": shape.scaleY < 0,
            "cut": shape.cutEnabled,
            "inside_cutting_area": shape.fits(in: mat.size),
            "line_count": shape.paths.count,
            "locked": shape.isLocked,
        ]
        if let g = shape.groupID { d["group"] = g.uuidString }
        if let c = shape.colorHex { d["color"] = c }
        if let t = shape.text {
            d["kind"] = "text"
            d["text"] = t.text
            d["font"] = t.fontName
            d["size_mm"] = t.sizeMM
        } else if let s = shape.effectiveShapeSpec {
            d["kind"] = s.kind.rawValue
            switch s.kind {
            case .rectangle: d["corner_radius"] = r(s.cornerRadiusMM)
            case .polygon: d["sides"] = s.sides
            case .star: d["points"] = s.sides; d["inner_ratio"] = r(s.innerRatio)
            case .ellipse: break
            }
        } else {
            d["kind"] = "path"
        }
        return d
    }

    static func describeDocument(_ data: ProjectData) -> [String: Any] {
        [
            "mat": data.mat.rawValue,
            "mat_width": r(data.mat.size.width),
            "mat_height": r(data.mat.size.height),
            "note": data.mat == .roll ? "Roll: the editor shows 600 mm, cutting is possible up to 3000 mm." : "",
            "objects": data.shapes.enumerated().map { describe($1, number: $0 + 1, mat: data.mat) },
        ]
    }

    // MARK: - Helpers

    /// Finds objects by id or number ("#3" or "3"). With `editing`,
    /// locked objects are refused: the user protected them.
    static func resolve(_ refs: [String], in data: ProjectData, editing: Bool = false) throws -> [UUID] {
        guard !refs.isEmpty else { throw ToolError("No objects given.") }
        let ids = try refs.map { ref in
            let t = ref.trimmingCharacters(in: .whitespaces)
            if let id = UUID(uuidString: t), data.shapes.contains(where: { $0.id == id }) { return id }
            let digits = t.hasPrefix("#") ? String(t.dropFirst()) : t
            if let n = Int(digits), n >= 1, n <= data.shapes.count { return data.shapes[n - 1].id }
            throw ToolError("No object “\(ref)”. Call get_document for the current ids.")
        }
        if editing, let locked = data.shapes.first(where: { ids.contains($0.id) && $0.isLocked }) {
            throw ToolError("Object “\(locked.name)” is locked by the user and cannot be changed.")
        }
        return ids
    }

    static func resolveOne(_ args: ToolArgs, in data: ProjectData, editing: Bool = false) throws -> UUID {
        try resolve([args.requiredString("id")], in: data, editing: editing)[0]
    }

    nonisolated static var actionName: String { String(localized: "AI edit") }

    /// Adds objects, selects them and returns their description.
    static func add(_ shapes: [CutShape], _ ctx: DocumentContext) -> [[String: Any]] {
        ctx.document.update(actionName, undoManager: ctx.undoManager) { $0.shapes.append(contentsOf: shapes) }
        ctx.select?(Set(shapes.map(\.id)))
        return [json(describe(ids: shapes.map(\.id), ctx))]
    }

    static func describe(ids: [UUID], _ ctx: DocumentContext) -> [[String: Any]] {
        let data = ctx.document.data
        return data.shapes.enumerated().compactMap { i, s in
            ids.contains(s.id) ? describe(s, number: i + 1, mat: data.mat) : nil
        }
    }

    /// Moves the object so its bounding box starts at x/y (if given).
    static func place(_ shape: inout CutShape, x: Double?, y: Double?) {
        let b = shape.matBounds
        if let x { shape.position.x += CGFloat(x) - b.minX }
        if let y { shape.position.y += CGFloat(y) - b.minY }
    }

    static func checkLength(_ v: Double?, _ name: String, min lo: Double = 0.1, max hi: Double = 3000) throws {
        if let v, !(lo...hi).contains(v) { throw ToolError("“\(name)” must be between \(lo) and \(hi) mm.") }
    }

    static func fontName(_ requested: String) throws -> String {
        let t = requested.trimmingCharacters(in: .whitespaces)
        // Family name first ("Futura" → "Futura-Medium"), then PostScript name
        if let family = FontCatalog.families.first(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            let faces = FontCatalog.faces(of: family)
            if let face = faces.first(where: { ["Regular", "Medium", "Roman", "Book"].contains($0.styleName) }) ?? faces.first {
                return face.postScriptName
            }
        }
        if FontCatalog.faces(of: FontCatalog.family(ofPostScriptName: t) ?? "").contains(where: { $0.postScriptName == t }) {
            return t
        }
        throw ToolError("Font “\(requested)” is not installed. Use list_fonts.")
    }

    static func shapeKind(_ raw: String) throws -> ShapeSpec.Kind {
        guard let k = ShapeSpec.Kind(rawValue: raw.lowercased()) else {
            throw ToolError("Unknown shape “\(raw)”. Use rectangle, ellipse, polygon or star.")
        }
        return k
    }

    // MARK: - Schemas

    static let num: [String: Any] = ["type": "number"]
    static let str: [String: Any] = ["type": "string"]
    static let bool: [String: Any] = ["type": "boolean"]
    static let ids: [String: Any] = ["type": "array", "items": ["type": "string"],
                                    "description": "Object ids or numbers like \"#2\"."]

    static func num(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
    static func str(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    static func choice(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }

    // MARK: - Tools

    static let all: [MCPTool] = [
        MCPTool(name: "get_document",
                description: "Mat size and all objects with id, number, kind, position, size and settings.",
                properties: [:], required: [], changes: false) { _, ctx in
            [json(describeDocument(ctx.document.data))]
        },

        MCPTool(name: "render_preview",
                description: "PNG picture of the mat with all objects, labelled with their numbers. Red = cut, grey dashed = not cut, orange = outside the cutting area.",
                properties: ["max_pixels": num("Longer side of the picture in pixels, 300–2000. Default 1200.")],
                required: [], changes: false) { args, ctx in
            let px = min(max(try args.int("max_pixels") ?? 1200, 300), 2000)
            guard let png = PreviewRenderer.png(of: ctx.document.data, maxPixels: px) else {
                throw ToolError("The preview could not be rendered.")
            }
            return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]
        },

        MCPTool(name: "add_svg",
                description: "Adds SVG artwork as one object. Paths, basic shapes and transforms are supported; text, images and fills are ignored, only outlines are cut. Units: width/height/viewBox of the SVG are honoured (mm, cm, in, px at 96 dpi). Use this for any free form design.",
                properties: [
                    "svg": str("Complete SVG document."),
                    "name": str("Object name."),
                    "x": num("Left edge on the mat (mm)."), "y": num("Top edge on the mat (mm)."),
                    "width": num("Scale to this width (mm), keeping proportions unless height is also given."),
                    "height": num("Scale to this height (mm)."),
                ], required: ["svg"], changes: true) { args, ctx in
            let svg = try args.requiredString("svg")
            let width = try args.double("width"), height = try args.double("height")
            try checkLength(width, "width"); try checkLength(height, "height")
            let result: ImportResult
            do { result = try SVGImporter.parse(Data(svg.utf8)) } catch {
                throw ToolError("The SVG could not be read: \(error.localizedDescription)")
            }
            guard !result.paths.isEmpty else {
                throw ToolError((["The SVG contains no lines that can be cut."] + result.warnings).joined(separator: " "))
            }
            var shape = CutShape(name: try args.string("name") ?? "SVG", matPaths: result.paths)
            if width != nil || height != nil {
                shape.resize(width: width, height: height, keepProportions: width == nil || height == nil)
            }
            let x = try args.double("x"), y = try args.double("y")
            if x == nil && y == nil { shape.placeInside(ctx.document.data.mat.displaySize) }
            place(&shape, x: x, y: y)
            var out = add([shape], ctx)
            if !result.warnings.isEmpty { out.append(text("Notes: " + result.warnings.joined(separator: " "))) }
            return out
        },

        MCPTool(name: "add_text",
                description: "Adds text as cut lines, using an installed Mac font.",
                properties: [
                    "text": str("The text; use \\n for more lines."),
                    "font": str("PostScript name (e.g. \"HelveticaNeue-Bold\") or family name (e.g. \"Futura\"). Default HelveticaNeue-Bold."),
                    "size_mm": num("Font size (em height) in mm. Default 20."),
                    "x": num("Left edge (mm). Default 20."), "y": num("Top edge (mm). Default 20."),
                ], required: ["text"], changes: true) { args, ctx in
            let font = try args.string("font").map(fontName) ?? FontCatalog.defaultFontName
            let size = try args.double("size_mm") ?? 20
            try checkLength(size, "size_mm", min: 1, max: 1000)
            let spec = TextSpec(text: try args.requiredString("text"), fontName: font, sizeMM: size)
            let origin = CGPoint(x: try args.double("x") ?? 20, y: try args.double("y") ?? 20)
            guard let shape = CutShape.text(spec, at: origin) else { throw ToolError("The text gives no lines.") }
            return add([shape], ctx)
        },

        MCPTool(name: "add_shape",
                description: "Adds a basic shape that stays editable: rectangle (optional rounded corners), ellipse, polygon, star.",
                properties: [
                    "kind": choice(ShapeSpec.Kind.allCases.map(\.rawValue), "Kind of shape."),
                    "width": num("Width (mm). Default 50."), "height": num("Height (mm). Default 50."),
                    "x": num("Left edge (mm). Default 20."), "y": num("Top edge (mm). Default 20."),
                    "corner_radius": num("Rectangle: corner radius (mm)."),
                    "sides": num("Polygon: corners (3–64). Star: points (3–64)."),
                    "inner_ratio": num("Star: inner radius as part of the outer radius, 0.1–0.95. Smaller = deeper points."),
                ], required: ["kind"], changes: true) { args, ctx in
            var spec = ShapeSpec.standard(try shapeKind(args.requiredString("kind")))
            if let w = try args.double("width") { try checkLength(w, "width", min: 1); spec.widthMM = w }
            if let h = try args.double("height") { try checkLength(h, "height", min: 1); spec.heightMM = h }
            if let c = try args.double("corner_radius") { spec.cornerRadiusMM = c }
            if let n = try args.int("sides") { spec.sides = n }
            if let q = try args.double("inner_ratio") { spec.innerRatio = q }
            let shape = CutShape.basic(spec, at: CGPoint(x: try args.double("x") ?? 20, y: try args.double("y") ?? 20))
            return add([shape], ctx)
        },

        MCPTool(name: "update_object",
                description: "Changes one object. Only the given values change; all values are final values on the mat. Order: text settings, size, shape settings, rotation, mirroring, then position.",
                properties: [
                    "id": str("Object id or number like \"#2\"."),
                    "name": str("New name."),
                    "x": num("Left edge of the bounding box (mm)."), "y": num("Top edge of the bounding box (mm)."),
                    "width": num("Width without rotation (mm)."), "height": num("Height without rotation (mm)."),
                    "keep_proportions": ["type": "boolean", "description": "When only width or height is given, scale the other side too. Default true."],
                    "rotation": num("Rotation in degrees, clockwise."),
                    "mirrored_horizontally": bool, "mirrored_vertically": bool,
                    "cut": ["type": "boolean", "description": "false keeps the object visible but it is not cut."],
                    "text": str("Text objects: new text."), "font": str("Text objects: font."), "size_mm": num("Text objects: font size (mm)."),
                    "corner_radius": num("Rectangles: corner radius (mm)."), "sides": num("Polygons/stars: corners or points."),
                    "inner_ratio": num("Stars: inner ratio 0.1–0.95."),
                    "order": choice(["front", "back"], "Bring to front or send to back (matters for subtract)."),
                ], required: ["id"], changes: true) { args, ctx in
            let id = try resolveOne(args, in: ctx.document.data, editing: true)
            guard var s = ctx.document.data.shapes.first(where: { $0.id == id }) else { throw ToolError("Object not found.") }

            if let name = try args.string("name") { s.name = name }
            if let cut = try args.bool("cut") { s.cutEnabled = cut }
            if args.has("text") || args.has("font") || args.has("size_mm") {
                guard var spec = s.text else { throw ToolError("“text”, “font” and “size_mm” only work on text objects.") }
                if let t = try args.string("text") { spec.text = t }
                if let f = try args.string("font") { spec.fontName = try fontName(f) }
                if let z = try args.double("size_mm") { try checkLength(z, "size_mm", min: 1, max: 1000); spec.sizeMM = z }
                guard s.updateText(spec) else { throw ToolError("The text gives no lines.") }
            }
            let w = try args.double("width"), h = try args.double("height")
            try checkLength(w, "width"); try checkLength(h, "height")
            if w != nil || h != nil {
                let keep = try args.bool("keep_proportions") ?? true
                s.resize(width: w, height: h, keepProportions: keep && (w == nil || h == nil))
            }
            if args.has("corner_radius") || args.has("sides") || args.has("inner_ratio") {
                guard var spec = s.effectiveShapeSpec else { throw ToolError("Shape settings only work on basic shapes.") }
                if let c = try args.double("corner_radius") { spec.cornerRadiusMM = c }
                if let n = try args.int("sides") { spec.sides = n }
                if let q = try args.double("inner_ratio") { spec.innerRatio = q }
                s.updateShapeSpec(spec)
            }
            if let rot = try args.double("rotation") { s.rotation = normalizedDegrees(rot) }
            if let m = try args.bool("mirrored_horizontally"), m != (s.scaleX < 0) { s.scaleX = -s.scaleX }
            if let m = try args.bool("mirrored_vertically"), m != (s.scaleY < 0) { s.scaleY = -s.scaleY }
            place(&s, x: try args.double("x"), y: try args.double("y"))
            let order = try args.string("order")
            if let order, order != "front", order != "back" { throw ToolError("“order” must be front or back.") }

            let updated = s
            ctx.document.update(actionName, undoManager: ctx.undoManager) { data in
                guard let i = data.shapes.firstIndex(where: { $0.id == id }) else { return }
                data.shapes[i] = updated
                if let order {
                    let moved = data.shapes.remove(at: i)
                    if order == "front" { data.shapes.append(moved) } else { data.shapes.insert(moved, at: 0) }
                }
            }
            ctx.select?([id])
            return [json(describe(ids: [id], ctx))]
        },

        MCPTool(name: "delete_objects", description: "Deletes objects.",
                properties: ["ids": ids], required: ["ids"], changes: true) { args, ctx in
            let found = Set(try resolve(args.strings("ids") ?? [], in: ctx.document.data, editing: true))
            ctx.document.update(actionName, undoManager: ctx.undoManager) { $0.shapes.removeAll { found.contains($0.id) } }
            ctx.select?([])
            return [text("Deleted \(found.count) object(s).")]
        },

        MCPTool(name: "duplicate_objects", description: "Copies objects, moved by dx/dy.",
                properties: ["ids": ids, "dx": num("Move copies right (mm). Default 5."), "dy": num("Move copies down (mm). Default 5.")],
                required: ["ids"], changes: true) { args, ctx in
            let found = try resolve(args.strings("ids") ?? [], in: ctx.document.data)
            let dx = CGFloat(try args.double("dx") ?? 5), dy = CGFloat(try args.double("dy") ?? 5)
            let copies = ctx.document.data.shapes.filter { found.contains($0.id) }.map { s -> CutShape in
                var c = s.duplicated(offset: 0)
                c.position.x += dx; c.position.y += dy
                c.isLocked = false
                c.groupID = nil
                return c
            }
            return add(copies, ctx)
        },

        MCPTool(name: "combine",
                description: "weld: join into one outline. subtract: cut the front objects out of the backmost one (order = list order in get_document, later = in front). intersect: keep only the common area. The objects are replaced by the result.",
                properties: ["operation": choice(PathOperation.allCases.map(\.rawValue), "Operation."), "ids": ids],
                required: ["operation", "ids"], changes: true) { args, ctx in
            guard let op = PathOperation(rawValue: try args.requiredString("operation")) else {
                throw ToolError("“operation” must be weld, subtract or intersect.")
            }
            let found = Set(try resolve(args.strings("ids") ?? [], in: ctx.document.data, editing: true))
            guard found.count >= 2 else { throw ToolError("Give at least two objects.") }
            guard let id = ctx.document.combine(op, ids: found, undoManager: ctx.undoManager) else {
                throw ToolError("The result would be empty. Check that the objects overlap.")
            }
            ctx.document.undoManagerActionRename(ctx.undoManager)
            ctx.select?([id])
            return [json(describe(ids: [id], ctx))]
        },

        MCPTool(name: "add_offset",
                description: "Adds an outline at a fixed distance around the objects (together), e.g. a sticker border. Negative distance = inwards. The originals stay.",
                properties: ["ids": ids, "distance": num("Distance in mm, -100…100."),
                             "corners": choice(["round", "sharp"], "Default round.")],
                required: ["ids", "distance"], changes: true) { args, ctx in
            let found = Set(try resolve(args.strings("ids") ?? [], in: ctx.document.data))
            let d = try args.double("distance") ?? 0
            guard (-100...100).contains(d), abs(d) >= 0.01 else { throw ToolError("“distance” must be between -100 and 100 mm and not 0.") }
            let round = (try args.string("corners") ?? "round") != "sharp"
            guard let id = ctx.document.addOffset(ids: found, distance: CGFloat(d), roundCorners: round, undoManager: ctx.undoManager) else {
                throw ToolError("The offset would be empty (inner offset larger than the object?).")
            }
            ctx.document.undoManagerActionRename(ctx.undoManager)
            ctx.select?([id])
            return [json(describe(ids: [id], ctx))]
        },

        MCPTool(name: "arrange",
                description: "Aligns objects to each other (one object: to the mat) or distributes three or more with equal gaps.",
                properties: ["ids": ids, "action": choice(AlignEdge.allCases.map(\.rawValue) + ["distribute_horizontal", "distribute_vertical"], "What to do.")],
                required: ["ids", "action"], changes: true) { args, ctx in
            let found = Set(try resolve(args.strings("ids") ?? [], in: ctx.document.data, editing: true))
            let action = try args.requiredString("action")
            if let edge = AlignEdge(rawValue: action) {
                ctx.document.align(edge, ids: found, undoManager: ctx.undoManager)
            } else if action == "distribute_horizontal" || action == "distribute_vertical" {
                guard found.count >= 3 else { throw ToolError("Distributing needs at least three objects.") }
                ctx.document.distribute(action == "distribute_horizontal" ? .horizontal : .vertical, ids: found, undoManager: ctx.undoManager)
            } else {
                throw ToolError("Unknown action “\(action)”.")
            }
            ctx.document.undoManagerActionRename(ctx.undoManager)
            return [json(describe(ids: Array(found), ctx))]
        },

        MCPTool(name: "set_mat", description: "Chooses the mat or roll in the plotter.",
                properties: ["mat": choice(MatType.allCases.map(\.rawValue), "12×12 inch mat, 12×24 inch mat, or roll.")],
                required: ["mat"], changes: true) { args, ctx in
            guard let mat = MatType(rawValue: try args.requiredString("mat")) else { throw ToolError("Unknown mat.") }
            ctx.document.update(actionName, undoManager: ctx.undoManager) { $0.mat = mat }
            return [text("Mat: \(mat.rawValue), cutting area \(r(mat.size.width)) × \(r(mat.size.height)) mm.")]
        },

        MCPTool(name: "list_fonts",
                description: "Installed font families. With a query, also lists the PostScript names of the matching families.",
                properties: ["query": str("Part of a family name, e.g. \"sans\" or \"Futura\".")],
                required: [], changes: false) { args, _ in
            let families = FontCatalog.families
            guard let q = try args.string("query"), !q.isEmpty else { return [json(families)] }
            let hits = families.filter { $0.localizedCaseInsensitiveContains(q) }.prefix(30)
            return [json(hits.map { f in ["family": f, "faces": FontCatalog.faces(of: f).map(\.postScriptName)] })]
        },

        MCPTool(name: "new_document", description: "Opens a new, empty Schnittwerk project window; the next tools work on it.",
                properties: [:], required: [], changes: false) { _, _ in
            [text("A new window was opened.")]
        },
    ]

    static func tool(named name: String) -> MCPTool? { all.first { $0.name == name } }
}

extension CutDocument {
    /// The model functions name their undo step after the operation;
    /// changes made through MCP are shown as one “AI edit” instead.
    func undoManagerActionRename(_ undoManager: UndoManager?) {
        undoManager?.setActionName(MCPTools.actionName)
    }
}
