// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Bluetooth LE connection to plotters of the Cameo 4 line. The plotter
// takes the same GPGL commands as over USB, through a vendor GATT
// service. Facts (UUIDs, "write with response only", ETX at the end of
// every write) were learned from the Inkcut project (pull request 441,
// tested on a Cameo 4 Plus); no code was copied.
//
// CoreBluetooth calls back on its own queue; the blocking methods below
// run on the plotter queue and wait for those callbacks.

import CoreBluetooth
import Foundation

final class CameoBluetooth: NSObject, PlotterTransport {
    static let serviceID = CBUUID(string: "E2088282-4FDE-42F9-BB22-6EC3C7ED8F91")
    static let writeID = CBUUID(string: "6D92661D-F429-4D67-929B-28E7A9780912")
    /// Replies to queries (status, firmware).
    static let readID = CBUUID(string: "8DCF199A-30E7-4BD4-BEB6-BEB57DCA866C")
    /// Status messages the plotter sends by itself.
    static let notifyID = CBUUID(string: "61490654-B5B4-458C-A867-9E15BC1471E0")

    /// How long to look for the plotter.
    static let scanTimeout: TimeInterval = 8

    private(set) var model = PlotterModel.cameo4
    /// Bluetooth name of the connected device, shown so the user sees
    /// which machine gets the job.
    private var deviceName = ""
    var displayName: String {
        deviceName.isEmpty ? "\(model.name) (Bluetooth)" : "\(model.name) (Bluetooth: \(deviceName))"
    }
    /// The plotter that worked last time; it is preferred over others.
    static let rememberedKey = "plotter.bluetoothID"
    private(set) var preferredChunkSize = 182

    private let cbQueue = DispatchQueue(label: "de.manuelweiser.schnittwerk.bluetooth")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var readChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    // Signals from the callbacks
    private let stateReady = DispatchSemaphore(value: 0)
    private let found = DispatchSemaphore(value: 0)
    private let connected = DispatchSemaphore(value: 0)
    private let discovered = DispatchSemaphore(value: 0)
    private let wrote = DispatchSemaphore(value: 0)
    private let dataArrived = DispatchSemaphore(value: 0)
    private let disconnected = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var incoming = Data()
    private var lastError: String?
    private var writeError: Error?

    deinit { close() }

    // MARK: - Open / close

    func open() throws {
        close()
        let central = CBCentralManager(delegate: self, queue: cbQueue)
        self.central = central
        guard stateReady.wait(timeout: .now() + 5) == .success else { throw PlotterError.bluetooth("no state") }
        switch central.state {
        case .poweredOn: break
        case .poweredOff: throw PlotterError.bluetoothOff
        case .unauthorized: throw PlotterError.bluetoothDenied
        default: throw PlotterError.notFound
        }

        // A plotter only advertises while nothing else is connected to it
        let known = central.retrieveConnectedPeripherals(withServices: [Self.serviceID])
        let remembered = UserDefaults.standard.string(forKey: Self.rememberedKey).flatMap(UUID.init(uuidString:))
        if let p = known.first(where: { $0.identifier == remembered }) ?? known.first {
            peripheral = p
        } else {
            central.scanForPeripherals(withServices: nil, options: nil)
            let result = found.wait(timeout: .now() + Self.scanTimeout)
            // Another plotter answered first: give the remembered one a moment
            if result == .success, let remembered,
               cbQueue.sync(execute: { peripheral?.identifier }) != remembered {
                Thread.sleep(forTimeInterval: 2)
            }
            cbQueue.sync { central.stopScan() }
            guard result == .success else { throw PlotterError.notFound }
        }
        guard let p = cbQueue.sync(execute: { peripheral }) else { throw PlotterError.notFound }
        p.delegate = self
        deviceName = p.name ?? ""
        model = PlotterModel.bluetooth(name: deviceName)

        central.connect(p, options: nil)
        guard connected.wait(timeout: .now() + 10) == .success, p.state == .connected else {
            throw PlotterError.bluetooth(takeError() ?? "connect")
        }
        p.discoverServices([Self.serviceID])
        guard discovered.wait(timeout: .now() + 10) == .success else { throw PlotterError.bluetooth("services") }
        // Only a device with the Silhouette service is accepted, whatever its name
        guard let service = p.services?.first(where: { $0.uuid == Self.serviceID }) else {
            throw PlotterError.bluetooth(String(localized: "This plotter offers no Cameo 4 Bluetooth service."))
        }
        p.discoverCharacteristics([Self.writeID, Self.readID, Self.notifyID], for: service)
        guard discovered.wait(timeout: .now() + 10) == .success else { throw PlotterError.bluetooth("characteristics") }
        let chars = service.characteristics ?? []
        writeChar = chars.first { $0.uuid == Self.writeID }
        readChar = chars.first { $0.uuid == Self.readID }
        notifyChar = chars.first { $0.uuid == Self.notifyID }
        guard writeChar != nil else { throw PlotterError.bluetooth("write characteristic") }

        for c in [readChar, notifyChar].compactMap({ $0 })
        where c.properties.contains(.notify) || c.properties.contains(.indicate) {
            p.setNotifyValue(true, for: c)
        }
        // Each write must end with ETX, so chunks may be at most one write long
        preferredChunkSize = max(min(p.maximumWriteValueLength(for: .withResponse), 512), 20)
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.rememberedKey)
    }

    func close() {
        guard let central else { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting {
            central.cancelPeripheralConnection(p)
            // Wait, so the plotter advertises again for the next job
            _ = disconnected.wait(timeout: .now() + 2)
        }
        peripheral = nil
        writeChar = nil
        readChar = nil
        notifyChar = nil
        self.central = nil
    }

    // MARK: - Transfer

    func write(_ data: Data, isCancelled: () -> Bool) throws {
        guard let p = peripheral, let c = writeChar, p.state == .connected else { throw PlotterError.notFound }
        var payload = data
        if payload.last != GPGLJob.etx { payload.append(GPGLJob.etx) }
        for piece in Self.pieces(of: payload, maxLength: preferredChunkSize) {
            let started = Date()
            while true {
                if isCancelled() { throw PlotterError.cancelled }
                writeError = nil
                p.writeValue(piece, for: c, type: .withResponse)
                // The answer may wait while the plotter's buffer is full
                guard wrote.wait(timeout: .now() + 30) == .success else {
                    if p.state != .connected { throw PlotterError.notFound }
                    if Date().timeIntervalSince(started) > 120 { throw PlotterError.timeout }
                    continue
                }
                guard let error = writeError else { break }
                if p.state != .connected { throw PlotterError.notFound }
                if Date().timeIntervalSince(started) > 120 {
                    throw PlotterError.bluetooth(error.localizedDescription)
                }
                // Busy: try the same piece again shortly
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    /// Splits after an ETX where possible; each piece is one BLE write.
    /// Only a single command longer than one write is cut in the middle.
    static func pieces(of data: Data, maxLength: Int) -> [Data] {
        let limit = max(maxLength, 1)
        guard data.count > limit else { return [data] }
        // Commands including their ETX
        var commands: [Data] = []
        var command = Data()
        for byte in data {
            command.append(byte)
            if byte == GPGLJob.etx { commands.append(command); command = Data() }
        }
        if !command.isEmpty { commands.append(command) }

        var result: [Data] = []
        var current = Data()
        for c in commands {
            if c.count > limit {
                if !current.isEmpty { result.append(current); current = Data() }
                var rest = c
                while !rest.isEmpty {
                    result.append(Data(rest.prefix(limit)))
                    rest = Data(rest.dropFirst(limit))
                }
                continue
            }
            if current.count + c.count > limit { result.append(current); current = Data() }
            current.append(c)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    func readReply(timeout: TimeInterval) throws -> String {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            lock.lock()
            if let i = incoming.firstIndex(of: GPGLJob.etx) {
                let reply = incoming[incoming.startIndex..<i]
                incoming.removeSubrange(incoming.startIndex...i)
                lock.unlock()
                return String(decoding: reply, as: UTF8.self)
            }
            lock.unlock()
            // A read characteristic without notifications must be asked
            if let p = peripheral, let r = readChar, !r.isNotifying, r.properties.contains(.read) {
                p.readValue(for: r)
            }
            _ = dataArrived.wait(timeout: .now() + 0.25)
        }
        throw PlotterError.timeout
    }

    func drain() {
        lock.lock()
        incoming.removeAll()
        lock.unlock()
        while dataArrived.wait(timeout: .now()) == .success {}
    }

    private func takeError() -> String? {
        lock.lock(); defer { lock.unlock() }
        let e = lastError
        lastError = nil
        return e
    }
}

// MARK: - CoreBluetooth callbacks (on cbQueue)

extension CameoBluetooth: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .unknown && central.state != .resetting { stateReady.signal() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let remembered = UserDefaults.standard.string(forKey: Self.rememberedKey).flatMap(UUID.init(uuidString:))
        // Another device was found first: switch only to the remembered one
        if let current = self.peripheral, current.identifier == remembered || peripheral.identifier != remembered { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = (peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "").lowercased()
        // The Cameo 3 offers this service too, but gave no answer to status queries
        // over it; it is reached over classic Bluetooth instead (CameoSerial)
        let classic = name.replacingOccurrences(of: " ", with: "").hasPrefix("cameo3")
        guard services.contains(Self.serviceID) || ((name.contains("cameo") || name.contains("silhouette")) && !classic)
        else { return }
        let first = self.peripheral == nil
        self.peripheral = peripheral
        if first { found.signal() }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected.signal()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lock.lock(); lastError = error?.localizedDescription; lock.unlock()
        connected.signal()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnected.signal()
        // Wake up anyone waiting, they check the state
        wrote.signal()
        dataArrived.signal()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        discovered.signal()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        discovered.signal()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeError = error
        wrote.signal()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value, !value.isEmpty else { return }
        // Replies come on the read characteristic; a plotter without one
        // answers on the notify characteristic
        let isReply = characteristic.uuid == Self.readID || (readChar == nil && characteristic.uuid == Self.notifyID)
        guard isReply else { return }
        lock.lock()
        incoming.append(value)
        lock.unlock()
        dataArrived.signal()
    }
}
