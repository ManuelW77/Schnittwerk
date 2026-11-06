// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

@MainActor
final class ProfileStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("schnittwerk-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testAddSaveAndReload() {
        var s = CutSettings()
        s.pressure = 21; s.speed = 4; s.depth = 5; s.passes = 2
        let store = ProfileStore(fileURL: url)
        let p = store.add(CutProfile(name: "Glitzerfolie", settings: s))

        let reloaded = ProfileStore(fileURL: url)
        XCTAssertEqual(reloaded.profiles, [p])
        XCTAssertEqual(reloaded.profile(settingsID: p.settingsID)?.pressure, 21)
    }

    func testApplyAndMatch() {
        var s = CutSettings()
        s.pressure = 21
        let p = CutProfile(name: "A", settings: s)
        var target = CutSettings()
        p.apply(to: &target)
        XCTAssertEqual(target.materialID, p.settingsID)
        XCTAssertTrue(p.matches(target))
        target.speed += 1
        XCTAssertFalse(p.matches(target))
    }

    func testDepthIgnoredForPen() {
        var s = CutSettings()
        s.tool = .pen
        let p = CutProfile(name: "Stift", settings: s)
        s.depth = 9
        XCTAssertTrue(p.matches(s))
    }

    func testUpdateRenameAndDelete() {
        let store = ProfileStore(fileURL: url)
        var p = store.add(CutProfile(name: "A", settings: CutSettings()))
        p.name = "  B  "
        p.pressure = 99 // clamped to 33
        store.update(p)
        XCTAssertEqual(store.profiles.first?.name, "B")
        XCTAssertEqual(store.profiles.first?.pressure, 33)

        p.name = "   " // empty name keeps the old one
        store.update(p)
        XCTAssertEqual(store.profiles.first?.name, "B")

        store.delete(id: p.id)
        XCTAssertTrue(ProfileStore(fileURL: url).profiles.isEmpty)
    }

    func testUniqueNames() {
        let store = ProfileStore(fileURL: url)
        store.add(CutProfile(name: "Vinyl", settings: CutSettings()))
        let second = store.add(CutProfile(name: "vinyl", settings: CutSettings()))
        XCTAssertEqual(second.name, "vinyl 2")
    }

    func testBrokenFileIsReportedAndKept() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kaputt".utf8).write(to: url)
        let store = ProfileStore(fileURL: url)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "kaputt")
    }

    func testUnknownIDsGiveNil() {
        let store = ProfileStore(fileURL: url)
        XCTAssertNil(store.profile(settingsID: "vinyl"))
        XCTAssertNil(store.profile(settingsID: "user:not-a-uuid"))
        XCTAssertNil(store.profile(settingsID: "user:\(UUID().uuidString)"))
    }
}
