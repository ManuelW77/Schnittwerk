// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// USB connection to the Cameo 4 via libusb. All calls block, so they
// must run off the main thread (PlotterController does that).

import Foundation

enum PlotterStatus: Equatable {
    case ready
    case moving
    case noMedia
    case unknown(String)

    init(reply: String) {
        switch reply.first {
        case "0": self = .ready
        case "1": self = .moving
        case "2": self = .noMedia
        default: self = .unknown(reply)
        }
    }
}

enum PlotterError: LocalizedError, Equatable {
    case notFound
    case busy
    case noMedia
    case timeout
    case cancelled
    case usb(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return String(localized: "No Cameo 4 found. Is it switched on and connected via USB?")
        case .busy:
            return String(localized: "The plotter is in use by another program. Quit Silhouette Studio and try again.")
        case .noMedia:
            return String(localized: "No mat or material loaded. Load it with the button on the plotter.")
        case .timeout:
            return String(localized: "The plotter did not respond in time.")
        case .cancelled:
            return String(localized: "Cancelled.")
        case .usb(let detail):
            return String(localized: "USB error: \(detail)")
        }
    }
}

final class CameoUSB {
    static let vendorID: UInt16 = 0x0B4D
    static let models: [UInt16: String] = [
        0x1137: "Cameo 4",
        0x1138: "Cameo 4 Plus",
        0x1139: "Cameo 4 Pro",
    ]

    private var context: OpaquePointer?
    private var handle: OpaquePointer?
    private var endpointOut: UInt8 = 0x01
    private var endpointIn: UInt8 = 0x82
    private(set) var modelName = ""

    deinit { close() }

    // MARK: - Open / close

    func open() throws {
        close()
        var ctx: OpaquePointer?
        try check(libusb_init(&ctx))
        context = ctx

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &list)
        guard count >= 0, let list else { throw PlotterError.usb(Self.errorName(Int32(count))) }
        defer { libusb_free_device_list(list, 1) }

        var found: OpaquePointer?
        for i in 0..<Int(count) {
            guard let dev = list[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0 else { continue }
            if desc.idVendor == Self.vendorID, let name = Self.models[desc.idProduct] {
                found = dev
                modelName = name
                break
            }
        }
        guard let device = found else { throw PlotterError.notFound }

        var h: OpaquePointer?
        let openResult = libusb_open(device, &h)
        if openResult == LIBUSB_ERROR_ACCESS.rawValue || openResult == LIBUSB_ERROR_BUSY.rawValue {
            throw PlotterError.busy
        }
        try check(openResult)
        handle = h

        findEndpoints(device)
        let claim = libusb_claim_interface(h, 0)
        if claim == LIBUSB_ERROR_ACCESS.rawValue || claim == LIBUSB_ERROR_BUSY.rawValue {
            throw PlotterError.busy
        }
        try check(claim)
    }

    func close() {
        if let h = handle {
            libusb_release_interface(h, 0)
            libusb_close(h)
            handle = nil
        }
        if let ctx = context {
            libusb_exit(ctx)
            context = nil
        }
    }

    /// Bulk endpoints of interface 0 (falls back to 0x01 / 0x82).
    private func findEndpoints(_ device: OpaquePointer) {
        var config: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(device, &config) == 0, let config else { return }
        defer { libusb_free_config_descriptor(config) }
        guard config.pointee.bNumInterfaces > 0, let iface = config.pointee.interface,
              iface.pointee.num_altsetting > 0, let alt = iface.pointee.altsetting else { return }
        let n = Int(alt.pointee.bNumEndpoints)
        guard n > 0, let eps = alt.pointee.endpoint else { return }
        for i in 0..<n {
            let ep = eps[i]
            guard ep.bmAttributes & 0x03 == 0x02 else { continue } // bulk
            if ep.bEndpointAddress & 0x80 != 0 { endpointIn = ep.bEndpointAddress } else { endpointOut = ep.bEndpointAddress }
        }
    }

    // MARK: - Transfer

    /// Sends all bytes. Waits while the plotter's buffer is full,
    /// up to `stallLimit` seconds without progress.
    func write(_ data: Data, stallLimit: TimeInterval = 120, isCancelled: () -> Bool = { false }) throws {
        guard let h = handle else { throw PlotterError.notFound }
        var bytes = [UInt8](data)
        var offset = 0
        var lastProgress = Date()
        while offset < bytes.count {
            if isCancelled() { throw PlotterError.cancelled }
            var sent: Int32 = 0
            let r = bytes.withUnsafeMutableBufferPointer { buf in
                libusb_bulk_transfer(h, endpointOut, buf.baseAddress! + offset, Int32(buf.count - offset), &sent, 2000)
            }
            offset += Int(sent)
            if sent > 0 { lastProgress = Date() }
            if r == 0 { continue }
            if r == LIBUSB_ERROR_TIMEOUT.rawValue {
                if Date().timeIntervalSince(lastProgress) > stallLimit { throw PlotterError.timeout }
                continue
            }
            if r == LIBUSB_ERROR_NO_DEVICE.rawValue { throw PlotterError.notFound }
            throw PlotterError.usb(Self.errorName(r))
        }
    }

    /// Reads up to `maxLength` bytes; returns empty data on timeout.
    func read(maxLength: Int = 64, timeoutMS: UInt32 = 1000) throws -> Data {
        guard let h = handle else { throw PlotterError.notFound }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        var got: Int32 = 0
        let r = libusb_bulk_transfer(h, endpointIn, &buffer, Int32(maxLength), &got, timeoutMS)
        if r == 0 || r == LIBUSB_ERROR_TIMEOUT.rawValue { return Data(buffer.prefix(Int(got))) }
        if r == LIBUSB_ERROR_NO_DEVICE.rawValue { throw PlotterError.notFound }
        throw PlotterError.usb(Self.errorName(r))
    }

    /// Reads until ETX (0x03) or timeout.
    func readReply(timeout: TimeInterval = 2) throws -> String {
        var reply = Data()
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let part = try read(timeoutMS: 250)
            reply.append(part)
            if let i = reply.firstIndex(of: GPGLJob.etx) {
                return String(decoding: reply[..<i], as: UTF8.self)
            }
        }
        throw PlotterError.timeout
    }

    /// Drops old replies still waiting in the plotter.
    func drain() {
        for _ in 0..<5 {
            guard let d = try? read(timeoutMS: 30), !d.isEmpty else { return }
        }
    }

    // MARK: - Commands

    static let escape: UInt8 = 0x1B

    func initialize() throws {
        try write(Data([Self.escape, 0x04]))
    }

    func status() throws -> PlotterStatus {
        drain()
        try write(Data([Self.escape, 0x05]))
        return PlotterStatus(reply: try readReply())
    }

    func firmwareVersion() throws -> String {
        drain()
        try write(Data("FG".utf8) + Data([GPGLJob.etx]))
        return try readReply().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private func check(_ result: Int32) throws {
        guard result < 0 else { return }
        throw PlotterError.usb(Self.errorName(result))
    }

    static func errorName(_ code: Int32) -> String {
        String(cString: libusb_error_name(code))
    }
}
