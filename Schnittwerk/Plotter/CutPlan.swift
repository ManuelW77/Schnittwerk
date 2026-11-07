// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// What the plotter will do, step by step, for the cut preview: the same
// order, strokes and clipping as GPGLBuilder, plus an estimate of the time.

import CoreGraphics
import Foundation

struct CutPlan {
    struct Step {
        /// Tool 1 or 2.
        let slot: Int
        let tool: ToolKind
        /// Stroke with the tool down (mat mm).
        let points: [CGPoint]
        /// Where the head comes from (tool up).
        let travelFrom: CGPoint
        let pass: Int
    }

    let steps: [Step]
    let cutLengthMM: CGFloat
    let travelMM: CGFloat
    let seconds: Double
    let toolChanges: Int

    /// Rough mm per second for a speed setting. Silhouette's speed n is
    /// about n cm/s; short lines never reach full speed, so every stroke
    /// costs a little extra.
    static func mmPerSecond(speed: Int) -> Double { Double(max(speed, 1)) * 10 }
    static let secondsPerStroke = 0.15
    static let secondsPerToolChange = 4.0

    static func make(for data: ProjectData, model: PlotterModel = .cameo4) -> CutPlan {
        var area = data.mat.size
        area.width = min(area.width, model.widthMM)
        var box = CGRect(origin: .zero, size: area)
        // Print & Cut: only the mark frame is cut
        if data.usesPrintAndCut, model.family != .classic {
            box = CGRect(origin: data.printCut.origin, size: data.printCut.frameSize)
        }
        var runs = GPGLBuilder.runs(for: data)
        if !model.twoTools, runs.count > 1 {
            runs = [GPGLBuilder.ToolRun(settings: runs[0].settings, paths: runs.flatMap(\.paths))]
        }
        var steps: [Step] = []
        var head = box.origin
        var cut: CGFloat = 0, travel: CGFloat = 0
        var seconds = 0.0
        for run in runs {
            let s = run.settings.clamped
            let slot = model.twoTools ? s.holder : 1
            let v = mmPerSecond(speed: min(s.speed, model.maxSpeed))
            let pieces = run.paths.flatMap { GPGLBuilder.clip($0, to: box) }
            for pass in 1...s.passes {
                for line in pieces {
                    for stroke in GPGLBuilder.strokes(line, settings: s) {
                        let pts = stroke.map { GPGLBuilder.clamp($0, to: box) }
                        guard let start = pts.first, pts.count >= 2 else { continue }
                        let length = Polyline(points: pts, closed: false).length
                        let move = head.distance(to: start)
                        steps.append(Step(slot: slot, tool: s.tool, points: pts, travelFrom: head, pass: pass))
                        cut += length
                        travel += move
                        // Travel runs at full speed of the machine
                        seconds += Double(length) / v + Double(move) / mmPerSecond(speed: model.maxSpeed)
                            + secondsPerStroke
                        head = pts.last ?? start
                    }
                }
            }
        }
        let changes = max(runs.count - 1, 0)
        seconds += Double(changes) * secondsPerToolChange
        return CutPlan(steps: steps, cutLengthMM: cut, travelMM: travel, seconds: seconds, toolChanges: changes)
    }
}
