// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Classic Bluetooth connection (serial port profile), used by the Cameo 3.
// Once the plotter is paired in System Settings → Bluetooth, macOS offers it
// as a serial port such as /dev/cu.CAMEO3-004651A. The same GPGL bytes as
// over USB go through it.

import Darwin
import Foundation

final class CameoSerial: PlotterTransport {
    private var fd: Int32 = -1
    private var portName = ""
    private(set) var model = PlotterModel.cameo3
    var displayName: String { "\(model.name) (Bluetooth: \(portName))" }
    let preferredChunkSize = 1024

    deinit { close() }

    /// Serial ports of paired Silhouette plotters, e.g. "/dev/cu.CAMEO3-004651A".
    static func ports(in names: [String]) -> [String] {
        names.filter { name in
            let n = name.lowercased()
            return n.hasPrefix("cu.") && (n.contains("cameo") || n.contains("silhouette") || n.contains("portrait"))
        }
        .sorted()
        .map { "/dev/" + $0 }
    }

    // MARK: - Open / close

    func open() throws {
        close()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        var lastError: Error = PlotterError.notFound
        for path in Self.ports(in: names) {
            do {
                try open(path)
                return
            } catch {
                close()
                lastError = error
            }
        }
        throw lastError
    }

    private func open(_ path: String) throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw errno == EBUSY ? PlotterError.busy : PlotterError.notFound
        }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &t)
        portName = (path as NSString).lastPathComponent.replacingOccurrences(of: "cu.", with: "")

        // A switched-off plotter keeps its port: only an answer counts
        drain()
        guard let firmware = try? ask("FG"), !firmware.isEmpty else { throw PlotterError.notFound }
        model = PlotterModel.named(firmware) ?? PlotterModel.named(portName) ?? .cameo3
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private func ask(_ command: String) throws -> String {
        try write(Data(command.utf8) + Data([GPGLJob.etx]), stallLimit: 3, isCancelled: { false })
        return try readReply(timeout: 3).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Transfer

    func write(_ data: Data, isCancelled: () -> Bool) throws {
        try write(data, stallLimit: 120, isCancelled: isCancelled)
    }

    /// Sends all bytes; waits while the plotter's buffer is full, up to
    /// `stallLimit` seconds without progress.
    private func write(_ data: Data, stallLimit: TimeInterval, isCancelled: () -> Bool) throws {
        guard fd >= 0 else { throw PlotterError.notFound }
        let bytes = [UInt8](data)
        var offset = 0
        var lastProgress = Date()
        while offset < bytes.count {
            if isCancelled() { throw PlotterError.cancelled }
            let n = bytes.withUnsafeBufferPointer { buf in
                Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
            }
            if n > 0 {
                offset += n
                lastProgress = Date()
                continue
            }
            if n < 0, errno != EAGAIN, errno != EINTR { throw PlotterError.notFound }
            if Date().timeIntervalSince(lastProgress) > stallLimit { throw PlotterError.timeout }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&p, 1, 250)
        }
    }

    func readReply(timeout: TimeInterval) throws -> String {
        guard fd >= 0 else { throw PlotterError.notFound }
        var reply = Data()
        let end = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 256)
        while Date() < end {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 250) > 0 else { continue }
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0, errno != EAGAIN, errno != EINTR { throw PlotterError.notFound }
            if n > 0 { reply.append(contentsOf: buffer[0..<n]) }
            if let i = reply.firstIndex(of: GPGLJob.etx) {
                return String(decoding: reply[..<i], as: UTF8.self)
            }
        }
        throw PlotterError.timeout
    }

    func drain() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 256)
        while Darwin.read(fd, &buffer, buffer.count) > 0 {}
    }
}
