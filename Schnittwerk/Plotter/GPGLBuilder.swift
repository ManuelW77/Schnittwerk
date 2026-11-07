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
    static func cutPaths(_ data: ProjectData) -> [Polyline] {
        let lines = data.shapes.filter(\.cutEnabled).flatMap(\.matPaths).filter { $0.points.count >= 2 }
        return ordered(lines)
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

    static func build(paths: [Polyline], settings rawSettings: CutSettings, mat: MatType,
                      model: PlotterModel = .cameo4) -> GPGLJob {
        let s = rawSettings.clamped
        // Machines with one tool holder (Portrait) know no holder 2
        let h = model.twoTools ? s.holder : 1
        var area = mat.size
        area.width = min(area.width, model.widthMM)
        var c: [String] = []

        let speed = min(s.speed, model.maxSpeed)
        // Blade tip offset 0.9 mm (18 units); a pen has none
        let offset = s.tool.isBlade ? "FC18,1,\(h)" : "FC0,1,\(h)"

        if model.family == .classic {
            // Older machines: no mat command, no tool holder, no AutoBlade.
            // FW300 = custom media, the values below apply.
            c.append("FW300")
            c.append("!\(speed)")
            c.append("FX\(s.pressure)")
            c.append(s.tool.isBlade ? "FC18" : "FC0")
            c.append("FY1")
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
            c.append("TB50,0")
            c.append("\\0,0")
            c.append("Z\(units(area.height)),\(units(area.width))")
            if model.twoTools { c.append("J\(h)") }
        }

        // Tool
        switch model.family {
        case .classic:
            break
        case .cameo4:
            if s.tool == .autoBlade {
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
            c.append("TJ3")
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
            if s.tool == .autoBlade {
                c.append("TF\(s.depth),\(h)")
            }
        }

        // Lines
        var maxY: CGFloat = 0
        var length: CGFloat = 0
        func clampPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, 0), area.width), y: min(max(p.y, 0), area.height))
        }
        for _ in 0..<s.passes {
            for line in paths {
                var pts = line.points.map(clampPoint)
                if line.closed, let first = pts.first { pts.append(first) }
                guard let first = pts.first, pts.count >= 2 else { continue }
                c.append("M\(units(first.y)),\(units(first.x))")
                for p in pts.dropFirst() {
                    c.append("D\(units(p.y)),\(units(p.x))")
                    maxY = max(maxY, p.y)
                }
                maxY = max(maxY, first.y)
                length += Polyline(points: pts, closed: false).length
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
        return GPGLJob(commands: c, pathCount: paths.count, cutLengthMM: length)
    }

    static func build(for data: ProjectData, model: PlotterModel = .cameo4) -> GPGLJob {
        build(paths: cutPaths(data), settings: data.settings, mat: data.mat, model: model)
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
