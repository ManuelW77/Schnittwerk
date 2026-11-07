// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class PlotterModelTests: XCTestCase {
    func testUSBLookup() {
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x1137)?.name, "Cameo 4")
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x1140)?.name, "Cameo 5")
        XCTAssertEqual(PlotterModel.usb(vendor: 0x0B4D, product: 0x113F)?.name, "Portrait 4")
        XCTAssertEqual(PlotterModel.usb(vendor: 0x3844, product: 0x0001)?.name, "Cameo 5 Alpha")
        XCTAssertNil(PlotterModel.usb(vendor: 0x0B4D, product: 0x112F), "Cameo 3 is not supported yet")
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
