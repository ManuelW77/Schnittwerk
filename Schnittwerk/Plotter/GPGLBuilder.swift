// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Builds the Graphtec/GPGL command stream for Silhouette plotters: the
// Cameo 4 line, the Cameo 3 and older machines (Cameo 1/2, Portrait 1/2).
// Protocol facts (units, command order) were learned from the
// open-source project inkscape-silhouette; no code was copied.
//
//   - every command ends with ETX (0x03)
//   - 20 plotter units per mm
//   - coordinates are "y,x": M = move up, D = cut down

import CoreGraphics
import Foundation

struct GPGLJob: Equatable {
    let commands: [String]
    let pathCount: Int
    /// Total cut length in mm (all passes).
    let cutLengthMM: CGFloat
    /// Print & Cut: after this many commands the plotter searches the
    /// marks; the rest may only be sent once it answers "0".
    var replyAfter: Int? = nil

    static let etx: UInt8 = 0x03

    /// Bytes for USB: each command followed by ETX.
    var data: Data {
        var d = Data()
        for c in commands {
            d.append(contentsOf: Array(c.utf8))
            d.append(Self.etx)
        }
        return d
    }

    /// Pieces of at most `maxBytes`, always cut after an ETX.
    func chunks(maxBytes: Int = 1024) -> [Data] {
        var result: [Data] = []
        var current = Data()
        for c in commands {
            var cmd = Data(c.utf8)
            cmd.append(Self.etx)
            if !current.isEmpty, current.count + cmd.count > maxBytes {
                result.append(current)
                current = Data()
            }
            current.append(cmd)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Readable form, one command per line (for checking without plotter).
    var text: String { commands.joined(separator: "\n") + "\n" }
}

enum GPGLBuilder {
    static let unitsPerMM: CGFloat = 20

    static func units(_ mm: CGFloat) -> Int { Int((mm * unitsPerMM).rounded()) }

    /// All lines to cut, in mat coordinates, in a good order.
    /// With `slot`, only the objects of tool 1 or 2.
    static func cutPaths(_ data: ProjectData, slot: Int? = nil) -> [Polyline] {
        let lines = data.shapes.filter { $0.cutEnabled && (slot == nil || $0.toolSlot == slot) }
            .flatMap(\.matPaths).filter { $0.points.count >= 2 }
        return ordered(lines)
    }

    /// The tool runs of a project. Tools that do not cut through (pen,
    /// embossing, punching) run first, so the material does not move yet.
    static func runs(for data: ProjectData) -> [ToolRun] {
        let runs = data.usedSlots.map { ToolRun(settings: data.settings(slot: $0), paths: cutPaths(data, slot: $0)) }
        return runs.filter { !$0.settings.tool.isBlade } + runs.filter { $0.settings.tool.isBlade }
    }

    /// Small and inner lines first (holes before the outline, so the
    /// material does not move), then the nearest next line.
    static func ordered(_ lines: [Polyline]) -> [Polyline] {
        let n = lines.count
        guard n > 1 else { return lines }
        let bounds = lines.map(\.bounds)
        let areas = bounds.map { $0.width * $0.height }

        // insideCount[i]: how many lines still lie inside line i.
        // containers[j]: lines that contain line j.
        var insideCount = [Int](repeating: 0, count: n)
        var containers = [[Int]](repeating: [], count: n)
        for i in 0..<n {
            for j in 0..<n where i != j && areas[j] < areas[i] && bounds[i].contains(bounds[j]) {
                insideCount[i] += 1
                containers[j].append(i)
            }
        }

        // A line may be cut once nothing is left inside it; among those,
        // take the one starting closest to the head to save travel.
        var done = [Bool](repeating: false, count: n)
        var result: [Polyline] = []
        result.reserveCapacity(n)
        var head = CGPoint.zero
        for _ in 0..<n {
            var best = -1
            var bestDistance = CGFloat.infinity
            for i in 0..<n where !done[i] && insideCount[i] == 0 {
                let d = (lines[i].points.first ?? .zero).distance(to: head)
                if d < bestDistance { bestDistance = d; best = i }
            }
            if best < 0 { best = (0..<n).first { !done[$0] }! } // safety net
            done[best] = true
            for c in containers[best] { insideCount[c] -= 1 }
            let line = lines[best]
            head = line.closed ? (line.points.first ?? head) : (line.points.last ?? head)
            result.append(line)
        }
        return result
    }

    /// Lines cut with one tool.
    struct ToolRun {
        var settings: CutSettings
        var paths: [Polyline]
    }

    static func build(paths: [Polyline], settings: CutSettings, mat: MatType,
                      model: PlotterModel = .cameo4) -> GPGLJob {
        build(runs: [ToolRun(settings: settings, paths: paths)], mat: mat, model: model)
    }

    /// One job with one or two tools. Each run selects its holder (`J`),
    /// sets its values and cuts its lines. Machines with one holder cut
    /// everything with the values of the first run.
    static func build(runs rawRuns: [ToolRun], mat: MatType, model: PlotterModel = .cameo4,
                      registration: PrintAndCut? = nil) -> GPGLJob {
        // Marks are searched by the Cameo 3 and the Cameo 4 line only
        let reg = model.family == .classic ? nil : registration
        var runs = rawRuns.filter { !$0.paths.isEmpty }
        if runs.isEmpty, let first = rawRuns.first { runs = [first] }
        if !model.twoTools, runs.count > 1 {
            runs = [ToolRun(settings: runs[0].settings, paths: runs.flatMap(\.paths))]
        }
        guard let firstRun = runs.first else {
            return build(runs: [ToolRun(settings: CutSettings(), paths: [])], mat: mat, model: model)
        }
        var area = mat.size
        area.width = min(area.width, model.widthMM)
        // With marks, coordinates start at the top left mark and the
        // cutting area is the mark frame
        var shift = CGAffineTransform.identity
        if let reg {
            area = reg.frameSize
            shift = CGAffineTransform(translationX: -reg.origin.x, y: -reg.origin.y)
        }
        var replyAfter: Int?
        var c: [String] = []

        let first = firstRun.settings.clamped
        if model.family == .classic {
            // Older machines: no mat command, no tool holder, no AutoBlade.
            // FW300 = custom media, the values below apply.
            c.append("FW300")
            c.append("!\(min(first.speed, model.maxSpeed))")
            c.append("FX\(first.pressure)")
            c.append("FC\(bladeOffset(first))")
            c.append(first.options.trackEnhancing ? "FY0" : "FY1")
            c.append("FN0")
            c.append("TB50,0")
            c.append("FE0,0")
            c.append("\\0,0")
            c.append("Z\(units(area.height)),\(units(area.width))")
            c.append("L0")
            c.append("FE0,0")
            c.append("FF0,0,0")
        } else {
            // Mat and cutting area
            c.append("TG\(mat.tgIndex)")
            c.append("FN0")
            if let reg {
                c.append(contentsOf: reg.searchCommands)
                replyAfter = c.count
            } else {
                c.append("TB50,0")
            }
            // Track enhancing: the rollers run over the mat first
            if runs.contains(where: { $0.settings.options.trackEnhancing }) { c.append("FY0") }
            c.append("\\0,0")
            c.append("Z\(units(area.height)),\(units(area.width))")
        }

        var maxY: CGFloat = 0
        var length: CGFloat = 0
        let box = CGRect(origin: .zero, size: area)
        for run in runs {
            let s = run.settings.clamped
            // Machines with one tool holder (Portrait) know no holder 2
            let h = model.twoTools ? s.holder : 1
            if model.family != .classic, model.twoTools { c.append("J\(h)") }
            c.append(contentsOf: toolCommands(s, holder: h, model: model))

            // Parts outside the cutting area are left out, so the blade
            // never runs along the edge of the mat
            let pieces = run.paths.map { $0.applying(shift) }.flatMap { clip($0, to: box) }
            for _ in 0..<s.passes {
                for line in pieces {
                    for stroke in strokes(line, settings: s) {
                        let pts = stroke.map { clamp($0, to: box) }
                        guard let start = pts.first, pts.count >= 2 else { continue }
                        c.append("M\(units(start.y)),\(units(start.x))")
                        for p in pts.dropFirst() {
                            c.append("D\(units(p.y)),\(units(p.x))")
                            maxY = max(maxY, p.y)
                        }
                        maxY = max(maxY, start.y)
                        length += Polyline(points: pts, closed: false).length
                    }
                }
            }
        }

        switch model.family {
        case .cameo4:
            // Move the head below the cut and finish
            c.append("M\(units(maxY)),0")
            c.append("SO0")
        case .cameo3, .classic:
            // Back to the origin, as Silhouette Studio does: a new origin
            // below the cut (SO0) makes the Cameo 3 keep the mat on unload
            // and moves the next job.
            c.append("L0")
            c.append("\\0,0")
            c.append("M0,0")
            if model.twoTools { c.append("J0") }
            c.append("FN0")
            c.append("TB50,0")
        }
        return GPGLJob(commands: c, pathCount: runs.reduce(0) { $0 + $1.paths.count }, cutLengthMM: length,
                       replyAfter: replyAfter)
    }

    /// Blade offset in plotter units: 0.9 mm (18 units) plus the
    /// correction; tools without a trailing blade tip have none.
    static func bladeOffset(_ s: CutSettings) -> Int {
        s.tool.isBlade ? max(0, 18 + s.options.offsetAdjust) : 0
    }

    /// Values of one tool: force, speed, depth, offset.
    static func toolCommands(_ s: CutSettings, holder h: Int, model: PlotterModel) -> [String] {
        let speed = min(s.speed, model.maxSpeed)
        let offset = "FC\(bladeOffset(s)),1,\(h)"
        var c: [String] = []
        switch model.family {
        case .classic:
            break // set in the header
        case .cameo4:
            if s.tool.setsDepth {
                c.append("TF\(s.depth),\(h)")
            }
            c.append("FX\(s.pressure),\(h)")
            c.append("TJ0")
            c.append("!\(speed),\(h)")
            c.append("FC0,1,\(h)")
            c.append("FE0,\(h)")
            c.append("FF1,0,\(h)")
            c.append("FF1,1,\(h)")
            c.append("FX\(s.pressure),\(h)")
            c.append("TJ\(s.options.acceleration)")
            c.append(offset)
        case .cameo3:
            // Same values, set once, without the acceleration command TJ
            c.append("!\(speed),\(h)")
            c.append("FX\(s.pressure),\(h)")
            c.append("FE0,\(h)")
            c.append("FF1,0,\(h)")
            c.append("FF1,1,\(h)")
            c.append("FC0,1,\(h)")
            if s.tool.isBlade { c.append(offset) }
            // Only the AutoBlade sets its depth on the Cameo 3
            if s.tool == .autoBlade {
                c.append("TF\(s.depth),\(h)")
            }
        }
        return c
    }

    /// The tool movements of one line: each stroke is cut in one go.
    /// Closed lines return to their start. A punch only pierces the
    /// centre; blades get the overcut and the sharp-corner moves.
    static func strokes(_ line: Polyline, settings s: CutSettings) -> [[CGPoint]] {
        if s.tool == .punch {
            let b = line.bounds
            guard !b.isNull else { return [] }
            let centre = CGPoint(x: b.midX, y: b.midY)
            return [[centre, centre]]
        }
        var pts = line.points
        guard pts.count >= 2 else { return [] }
        if line.closed, let first = pts.first { pts.append(first) }
        guard s.tool.isBlade else { return [pts] }

        if s.options.overcut, line.closed {
            pts += walk(along: Array(line.points) + [line.points[0]], distance: CutOptions.overcutMM)
        }
        guard s.options.sharpCorners, pts.count >= 3 else { return [pts] }

        // Split at sharp corners: run past the corner, lift, start again there
        var result: [[CGPoint]] = []
        var current = [pts[0]]
        for i in 1..<(pts.count - 1) {
            let a = pts[i - 1], p = pts[i], b = pts[i + 1]
            current.append(p)
            let inDir = CGVector(dx: p.x - a.x, dy: p.y - a.y)
            let outDir = CGVector(dx: b.x - p.x, dy: b.y - p.y)
            let inLen = hypot(inDir.dx, inDir.dy), outLen = hypot(outDir.dx, outDir.dy)
            guard inLen > 1e-6, outLen > 1e-6 else { continue }
            let cosine = (inDir.dx * outDir.dx + inDir.dy * outDir.dy) / (inLen * outLen)
            let turn = acos(min(max(cosine, -1), 1)) * 180 / .pi
            guard turn >= CutOptions.sharpCornerAngle else { continue }
            let o = CutOptions.cornerOvershootMM
            current.append(CGPoint(x: p.x + inDir.dx / inLen * o, y: p.y + inDir.dy / inLen * o))
            result.append(current)
            current = [p]
        }
        current.append(pts[pts.count - 1])
        result.append(current)
        return result.filter { $0.count >= 2 }
    }

    /// Points along `pts` from its start up to `distance` mm (without the start).
    static func walk(along pts: [CGPoint], distance: CGFloat) -> [CGPoint] {
        var left = distance
        var out: [CGPoint] = []
        for (a, b) in zip(pts, pts.dropFirst()) {
            let d = a.distance(to: b)
            guard d > 1e-9 else { continue }
            if d >= left {
                out.append(CGPoint(x: a.x + (b.x - a.x) * left / d, y: a.y + (b.y - a.y) * left / d))
                return out
            }
            out.append(b)
            left -= d
        }
        return out
    }

    static func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    /// The parts of `line` that lie inside `rect`. A line fully inside comes
    /// back unchanged; otherwise each inside stretch becomes an open line.
    static func clip(_ line: Polyline, to rect: CGRect) -> [Polyline] {
        let box = rect.insetBy(dx: -0.001, dy: -0.001)
        if line.points.allSatisfy({ box.contains($0) }) { return [line] }
        var pts = line.points
        if line.closed, let first = pts.first { pts.append(first) }

        var result: [Polyline] = []
        var current: [CGPoint] = []
        func flush() {
            if current.count >= 2 { result.append(Polyline(points: current, closed: false)) }
            current = []
        }
        for (a, b) in zip(pts, pts.dropFirst()) {
            guard let (p, q) = clipSegment(a, b, to: rect) else { flush(); continue }
            if let last = current.last, last.distance(to: p) > 1e-6 { flush() }
            if current.isEmpty { current.append(p) }
            current.append(q)
            if q.distance(to: b) > 1e-6 { flush() } // left the area
        }
        flush()
        return result
    }

    /// Liang–Barsky: the part of segment a→b inside `rect`, if any.
    static func clipSegment(_ a: CGPoint, _ b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint)? {
        let dx = b.x - a.x, dy = b.y - a.y
        var t0: CGFloat = 0, t1: CGFloat = 1
        let checks: [(CGFloat, CGFloat)] = [
            (-dx, a.x - rect.minX), (dx, rect.maxX - a.x),
            (-dy, a.y - rect.minY), (dy, rect.maxY - a.y),
        ]
        for (p, q) in checks {
            if p == 0 {
                if q < 0 { return nil }
            } else {
                let r = q / p
                if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
                if t0 > t1 { return nil }
            }
        }
        let p = CGPoint(x: a.x + t0 * dx, y: a.y + t0 * dy)
        let q = CGPoint(x: a.x + t1 * dx, y: a.y + t1 * dy)
        return p.distance(to: q) > 1e-6 ? (p, q) : nil
    }

    static func build(for data: ProjectData, model: PlotterModel = .cameo4) -> GPGLJob {
        let runs = runs(for: data)
        if runs.isEmpty { return build(paths: [], settings: data.settings(slot: 1), mat: data.mat, model: model) }
        return build(runs: runs, mat: data.mat, model: model,
                     registration: data.usesPrintAndCut ? data.printCut : nil)
    }

    /// Small test cut: 10 mm square with a triangle inside, at the top left.
    static func testCut(settings: CutSettings, mat: MatType, model: PlotterModel = .cameo4,
                        origin: CGPoint = CGPoint(x: 10, y: 10)) -> GPGLJob {
        let o = origin
        let square = Polyline(points: [o, CGPoint(x: o.x + 10, y: o.y), CGPoint(x: o.x + 10, y: o.y + 10),
                                       CGPoint(x: o.x, y: o.y + 10)], closed: true)
        let triangle = Polyline(points: [CGPoint(x: o.x + 2, y: o.y + 8), CGPoint(x: o.x + 5, y: o.y + 2),
                                         CGPoint(x: o.x + 8, y: o.y + 8)], closed: true)
        return build(paths: [triangle, square], settings: settings, mat: mat, model: model)
    }
}
