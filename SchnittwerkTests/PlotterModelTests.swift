// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class PlotterModelTests: XCTestCase {
    func testUSBLookup() {
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x1137)?.name, "Cameo 4")
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x1140)?.name, "Cameo 5")
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x113F)?.name, "Portrait 4")
        XCTAssertEqual(PlotterModel.usb(vendor: 0x3844, product: 0x0001)?.name, "Cameo 5 Alpha")
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x112F)?.name, "Cameo 3")
        XCTAssertNil(PlotterModel.usb(vendor: 0x1234, product: 0x1137))
    }

    func testIDsAreUnique() {
        let keys = PlotterModel.all.map { "\($0.vendorID)-\($0.productID)" }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testBluetoothNames() {
        XCTAssertEqual(PlotterModel.bluetooth(name: "CAMEO 4 PLUS").name, "Cameo 4 Plus")
        XCTAssertEqual(PlotterModel.bluetooth(name: "Cameo4 Pro-1234").name, "Cameo 4 Pro")
        XCTAssertEqual(PlotterModel.bluetooth(name: "CAMEO 4").name, "Cameo 4")
        XCTAssertEqual(PlotterModel.bluetooth(name: "").name, "Cameo 4")
    }

    func testPortraitGetsNoToolSelectAndNarrowArea() throws {
        let portrait = try XCTUnwrap(PlotterModel.all.first { $0.name == "Portrait 3" })
        var settings = CutSettings()
        settings.holder = 2
        let job = GPGLBuilder.testCut(settings: settings, mat: .mat12x12, model: portrait)
        XCTAssertFalse(job.commands.contains { $0.hasPrefix("J") })
        XCTAssertTrue(job.commands.contains("FX\(settings.pressure),1"), "holder 1 only")
        XCTAssertTrue(job.commands.contains("Z\(GPGLBuilder.units(304.8)),\(GPGLBuilder.units(203))"))
    }

    func testCameo4CommandsUnchanged() {
        var settings = CutSettings()
        settings.holder = 2
        let job = GPGLBuilder.testCut(settings: settings, mat: .mat12x12)
        XCTAssertTrue(job.commands.contains("J2"))
        XCTAssertTrue(job.commands.contains("Z\(GPGLBuilder.units(304.8)),\(GPGLBuilder.units(304.8))"))
    }

    func testCameo3HeaderHasNoAccelerationAndSlowSpeed() {
        var s = CutSettings()
        s.tool = .autoBlade; s.depth = 3; s.pressure = 12; s.speed = 20; s.holder = 1
        let job = GPGLBuilder.testCut(settings: s, mat: .mat12x12, model: .cameo3)
        XCTAssertEqual(Array(job.commands.prefix(14)), [
            "TG1", "FN0", "TB50,0", "\\0,0", "Z6096,6096",
            "J1", "!10,1", "FX12,1", "FE0,1", "FF1,0,1", "FF1,1,1", "FC0,1,1", "FC18,1,1", "TF3,1",
        ])
        XCTAssertFalse(job.commands.contains { $0.hasPrefix("TJ") })
        XCTAssertEqual(job.commands.suffix(1), ["SO0"])
    }

    func testCameo3PenHasNoBladeOffset() {
        var s = CutSettings()
        s.tool = .pen; s.holder = 2
        let job = GPGLBuilder.testCut(settings: s, mat: .mat12x12, model: .cameo3)
        XCTAssertTrue(job.commands.contains("J2"))
        XCTAssertTrue(job.commands.contains("FC0,1,2"))
        XCTAssertFalse(job.commands.contains("FC18,1,2"))
        XCTAssertFalse(job.commands.contains { $0.hasPrefix("TF") })
    }

    func testOlderMachinesAreFound() {
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x112B)?.family, .classic)
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x1121)?.name, "Cameo")
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x1132)?.name, "Portrait 2")
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x1123)?.name, "Portrait")
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x110A)?.name, "Craft Robo CC200-20")
    }

    func testClassicHeaderHasNoMatNoToolHolder() throws {
        let cameo2 = try XCTUnwrap(PlotterModel.usb(vendor: 0x0B4D, product: 0x112B))
        var s = CutSettings()
        s.tool = .autoBlade; s.depth = 3; s.pressure = 12; s.speed = 20; s.holder = 2
        let job = GPGLBuilder.testCut(settings: s, mat: .mat12x12, model: cameo2)
        XCTAssertEqual(Array(job.commands.prefix(14)), [
            "FW300", "!10", "FX12", "FC18", "FY1", "FN0", "TB50,0", "FE0,0",
            "\\0,0", "Z6096,6080", "L0", "FE0,0", "FF0,0,0", "M360,240",
        ])
        XCTAssertFalse(job.commands.contains { $0.hasPrefix("TG") || $0.hasPrefix("J") || $0.hasPrefix("TF") })
        XCTAssertEqual(job.commands.suffix(1), ["SO0"])
    }

    func testClassicPenHasNoOffset() throws {
        let portrait = try XCTUnwrap(PlotterModel.usb(vendor: 0x0B4D, product: 0x1123))
        var s = CutSettings()
        s.tool = .pen
        let job = GPGLBuilder.testCut(settings: s, mat: .mat12x12, model: portrait)
        XCTAssertTrue(job.commands.contains("FC0"))
        XCTAssertFalse(job.commands.contains("FC18"))
        XCTAssertTrue(job.commands.contains("Z6096,4120"))
    }

    func testModelFromFirmwareAndBluetoothName() {
        XCTAssertEqual(PlotterModel.named("CAMEO 3 V1.70    ")?.name, "Cameo 3")
        XCTAssertEqual(PlotterModel.named("CAMEO3-004651A")?.name, "Cameo 3")
        XCTAssertEqual(PlotterModel.named("CAMEO 4 PLUS V1.20")?.name, "Cameo 4 Plus")
        XCTAssertEqual(PlotterModel.named("CAMEO V2.00")?.name, "Cameo")
        XCTAssertNil(PlotterModel.named("Beats Studio Pro"))
    }

    func testSerialPortsOnlyPlotters() {
        let names = ["cu.CAMEO3-004651A", "tty.CAMEO3-004651A", "cu.BeatsStudioProvonManuel",
                     "cu.Bluetooth-Incoming-Port", "cu.debug-console"]
        XCTAssertEqual(CameoSerial.ports(in: names), ["/dev/cu.CAMEO3-004651A"])
    }

    func testCameo4KeepsFastSpeed() {
        var s = CutSettings()
        s.speed = 20
        XCTAssertTrue(GPGLBuilder.testCut(settings: s, mat: .mat12x12).commands.contains("!20,1"))
    }

    func testBluetoothPiecesEndAfterETX() {
        let etx = GPGLJob.etx
        var data = Data()
        for command in ["M10,20", "D30,40", "D50,60"] {
            data.append(contentsOf: Array(command.utf8))
            data.append(etx)
        }
        let pieces = CameoBluetooth.pieces(of: data, maxLength: 15)
        // Three commands of 7 bytes: two fit into 15, the third goes alone
        XCTAssertEqual(pieces.map { $0.count }, [14, 7])
        XCTAssertEqual(joined(pieces), data)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 15 && $0.last == etx })
    }

    func testBluetoothSplitsLongCommand() {
        let etx = GPGLJob.etx
        var data = Data(repeating: 0x41, count: 30)
        data.append(etx)
        let pieces = CameoBluetooth.pieces(of: data, maxLength: 10)
        XCTAssertEqual(pieces.map { $0.count }, [10, 10, 10, 1])
        XCTAssertEqual(joined(pieces), data)
    }

    func testSmallDataIsOnePiece() {
        let data = Data([0x1B, 0x05, GPGLJob.etx])
        XCTAssertEqual(CameoBluetooth.pieces(of: data, maxLength: 182), [data])
    }

    private func joined(_ pieces: [Data]) -> Data {
        var all = Data()
        for p in pieces { all.append(p) }
        return all
    }
}
