// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// A connection to the plotter, over USB or Bluetooth. All calls block,
// so they run on the plotter queue, never on the main thread.

import Foundation

protocol PlotterTransport: AnyObject {
    /// The connected model (known after `open`).
    var model: PlotterModel { get }
    /// Shown to the user, e.g. "Cameo 4 (Bluetooth)".
    var displayName: String { get }
    /// Largest piece `write` should get at once (cut after an ETX).
    var preferredChunkSize: Int { get }

    func open() throws
    func close()
    /// Sends all bytes, waiting while the plotter is busy.
    func write(_ data: Data, isCancelled: () -> Bool) throws
    /// Reads until ETX (0x03) or timeout.
    func readReply(timeout: TimeInterval) throws -> String
    /// Drops old replies still waiting.
    func drain()
}

/// How Schnittwerk looks for the plotter.
enum ConnectionKind: String, CaseIterable, Identifiable {
    /// USB first, then Bluetooth.
    case automatic, usb, bluetooth
    var id: String { rawValue }

    static let storageKey = "plotter.connection"

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .usb: String(localized: "USB")
        case .bluetooth: String(localized: "Bluetooth")
        }
    }

    static var current: ConnectionKind {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ConnectionKind.init) ?? .automatic
    }
}

enum PlotterConnection {
    /// Opens the plotter the chosen way.
    static func open(_ kind: ConnectionKind = .current) throws -> PlotterTransport {
        switch kind {
        case .usb:
            return try opened(CameoUSB())
        case .bluetooth:
            return try opened(CameoBluetooth())
        case .automatic:
            do {
                return try opened(CameoUSB())
            } catch PlotterError.notFound {
                do {
                    return try opened(CameoBluetooth())
                } catch PlotterError.notFound, PlotterError.bluetoothOff {
                    throw PlotterError.notFound
                }
            }
        }
    }

    private static func opened(_ t: PlotterTransport) throws -> PlotterTransport {
        try t.open()
        return t
    }
}

// MARK: - Commands shared by all connections

extension PlotterTransport {
    static var escape: UInt8 { 0x1B }

    func write(_ data: Data) throws { try write(data, isCancelled: { false }) }

    func initialize() throws {
        try write(Data([Self.escape, 0x04]))
    }

    func status() throws -> PlotterStatus {
        drain()
        try write(Data([Self.escape, 0x05]))
        return PlotterStatus(reply: try readReply(timeout: 2))
    }

    func firmwareVersion() throws -> String {
        drain()
        try write(Data("FG".utf8) + Data([GPGLJob.etx]))
        return try readReply(timeout: 2).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
