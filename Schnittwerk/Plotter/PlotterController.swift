// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Runs plotter jobs on a background queue and reports progress to the UI.
@MainActor
final class PlotterController: ObservableObject {
    static let shared = PlotterController()

    enum Phase: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 0…1 while sending, nil otherwise.
    @Published private(set) var progress: Double?
    @Published private(set) var deviceInfo: String?
    /// Model of the plotter found last (Cameo 4 until one was found).
    @Published private(set) var lastModel = PlotterModel.cameo4

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    private let queue = DispatchQueue(label: "de.manuelweiser.schnittwerk.plotter")
    private var cancelFlag = CancelFlag()

    // MARK: - Actions

    func checkConnection() {
        guard !isBusy else { return }
        phase = .working(String(localized: "Looking for the plotter…"))
        queue.async {
            do {
                let plotter = try PlotterConnection.open()
                defer { plotter.close() }
                try plotter.initialize()
                let status = try plotter.status()
                let firmware = (try? plotter.firmwareVersion()) ?? ""
                let info = firmware.isEmpty ? plotter.displayName : "\(plotter.displayName) · \(firmware)"
                let text: String
                switch status {
                case .ready: text = String(localized: "Ready")
                case .moving: text = String(localized: "Busy")
                case .noMedia: text = String(localized: "Connected, no mat loaded")
                case .unknown(let r): text = String(localized: "Connected, unknown status “\(r)”")
                }
                let model = plotter.model
                Task { @MainActor in
                    self.deviceInfo = info
                    self.lastModel = model
                    self.phase = .done("\(info): \(text)")
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    self.deviceInfo = nil
                    self.phase = .failed(message)
                }
            }
        }
    }

    /// Sends the job built for the connected model.
    func send(_ build: @escaping @Sendable (PlotterModel) -> GPGLJob) {
        guard !isBusy else { return }
        let flag = CancelFlag()
        cancelFlag = flag
        phase = .working(String(localized: "Connecting…"))
        progress = 0
        queue.async {
            do {
                let plotter = try PlotterConnection.open()
                defer { plotter.close() }
                let model = plotter.model
                Task { @MainActor in self.lastModel = model }
                try plotter.initialize()
                try Self.waitUntilReady(plotter, flag: flag, limit: 15)
                Self.report(String(localized: "Cutting…"), progress: 0)

                var job = build(model)
                if let n = job.replyAfter {
                    // Print & Cut: let the plotter find the marks first
                    Self.report(String(localized: "Looking for the registration marks…"), progress: 0)
                    plotter.drain()
                    let search = GPGLJob(commands: Array(job.commands.prefix(n)), pathCount: 0, cutLengthMM: 0)
                    for chunk in search.chunks(maxBytes: plotter.preferredChunkSize) {
                        try plotter.write(chunk, isCancelled: flag.isSet)
                    }
                    let reply = try plotter.readReply(timeout: 40).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard reply == "0" else { throw PlotterError.marksNotFound(reply) }
                    job = GPGLJob(commands: Array(job.commands.dropFirst(n)), pathCount: job.pathCount,
                                  cutLengthMM: job.cutLengthMM)
                    Self.report(String(localized: "Cutting…"), progress: 0)
                }
                let chunks = job.chunks(maxBytes: plotter.preferredChunkSize)
                for (i, chunk) in chunks.enumerated() {
                    try plotter.write(chunk, isCancelled: flag.isSet)
                    Self.report(nil, progress: Double(i + 1) / Double(chunks.count))
                }
                Self.report(String(localized: "Finishing…"), progress: 1)
                try Self.waitUntilReady(plotter, flag: flag, limit: 3600)
                Task { @MainActor in
                    self.progress = nil
                    self.phase = .done(String(localized: "Done. Unload the mat with the button on the plotter."))
                }
            } catch {
                let message: String
                if (error as? PlotterError) == .cancelled {
                    message = String(localized: "Cancelled. Commands already sent are still being cut; press pause on the plotter to stop at once.")
                } else {
                    message = error.localizedDescription
                }
                Task { @MainActor in
                    self.progress = nil
                    self.phase = .failed(message)
                }
            }
        }
    }

    func cancel() {
        cancelFlag.set()
    }

    func reset() {
        if !isBusy { phase = .idle }
    }

    // MARK: - Background helpers

    nonisolated private static func report(_ text: String?, progress: Double) {
        Task { @MainActor in
            let c = PlotterController.shared
            if let text { c.phase = .working(text) }
            c.progress = progress
        }
    }

    /// Polls the status until the plotter is idle.
    nonisolated private static func waitUntilReady(_ plotter: PlotterTransport, flag: CancelFlag, limit: TimeInterval) throws {
        let end = Date().addingTimeInterval(limit)
        while true {
            if flag.isSet() { throw PlotterError.cancelled }
            switch try plotter.status() {
            case .ready: return
            case .noMedia: throw PlotterError.noMedia
            case .moving, .unknown: break
            }
            if Date() > end { throw PlotterError.timeout }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

/// Thread-safe cancel switch for the USB queue.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.lock(); value = true; lock.unlock() }

    func isSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
