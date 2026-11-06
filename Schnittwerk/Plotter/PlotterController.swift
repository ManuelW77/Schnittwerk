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

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    private let queue = DispatchQueue(label: "de.manuelweiser.schnittwerk.usb")
    private var cancelFlag = CancelFlag()

    // MARK: - Actions

    func checkConnection() {
        guard !isBusy else { return }
        phase = .working(String(localized: "Looking for the plotter…"))
        queue.async {
            let usb = CameoUSB()
            defer { usb.close() }
            do {
                try usb.open()
                try usb.initialize()
                let status = try usb.status()
                let firmware = (try? usb.firmwareVersion()) ?? ""
                let info = firmware.isEmpty ? usb.modelName : "\(usb.modelName) · \(firmware)"
                let text: String
                switch status {
                case .ready: text = String(localized: "Ready")
                case .moving: text = String(localized: "Busy")
                case .noMedia: text = String(localized: "Connected, no mat loaded")
                case .unknown(let r): text = String(localized: "Connected, unknown status “\(r)”")
                }
                Task { @MainActor in
                    self.deviceInfo = info
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

    func send(_ job: GPGLJob) {
        guard !isBusy else { return }
        let flag = CancelFlag()
        cancelFlag = flag
        phase = .working(String(localized: "Connecting…"))
        progress = 0
        queue.async {
            let usb = CameoUSB()
            defer { usb.close() }
            do {
                try usb.open()
                try usb.initialize()
                try Self.waitUntilReady(usb, flag: flag, limit: 15)
                Self.report(String(localized: "Cutting…"), progress: 0)

                let chunks = job.chunks()
                for (i, chunk) in chunks.enumerated() {
                    try usb.write(chunk, isCancelled: flag.isSet)
                    Self.report(nil, progress: Double(i + 1) / Double(chunks.count))
                }
                Self.report(String(localized: "Finishing…"), progress: 1)
                try Self.waitUntilReady(usb, flag: flag, limit: 3600)
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
    nonisolated private static func waitUntilReady(_ usb: CameoUSB, flag: CancelFlag, limit: TimeInterval) throws {
        let end = Date().addingTimeInterval(limit)
        while true {
            if flag.isSet() { throw PlotterError.cancelled }
            switch try usb.status() {
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
