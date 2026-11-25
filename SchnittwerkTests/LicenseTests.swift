// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import StoreKit
import XCTest
@testable import Schnittwerk

final class LicenseTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func day(_ n: Double, hours: Double = 0) -> Date { start.addingTimeInterval(n * 86_400 + hours * 3_600) }

    func testDayZero() {
        XCTAssertEqual(TrialPolicy.status(start: start, now: start, purchased: false), .trial(daysLeft: 7))
    }

    func testDaySix() {
        XCTAssertEqual(TrialPolicy.status(start: start, now: day(6, hours: 23), purchased: false), .trial(daysLeft: 1))
    }

    func testDaySevenExpires() {
        XCTAssertEqual(TrialPolicy.status(start: start, now: day(7), purchased: false), .expired)
        XCTAssertEqual(TrialPolicy.status(start: start, now: day(30), purchased: false), .expired)
        XCTAssertFalse(LicenseStatus.expired.canCut)
    }

    func testPurchasedAlwaysUnlocked() {
        XCTAssertEqual(TrialPolicy.status(start: start, now: day(400), purchased: true), .purchased)
        XCTAssertTrue(LicenseStatus.purchased.canCut)
    }

    func testUnknownStartUnlocks() {
        XCTAssertEqual(TrialPolicy.status(start: nil, now: day(400), purchased: false), .trial(daysLeft: 7))
    }

    func testClockBeforeStartUnlocks() {
        XCTAssertEqual(TrialPolicy.status(start: start, now: day(-3), purchased: false), .trial(daysLeft: 7))
    }

    private struct FakeSource: LicenseSource {
        var start: Date?
        var purchased: Bool
        func trialStart() async -> Date? { start }
        func hasPurchase() async -> Bool { purchased }
        func product() async -> Product? { nil }
    }

    @MainActor
    func testStoreUsesInjectedSourceAndDate() async {
        let now = day(8)
        let store = LicenseStore(source: FakeSource(start: start, purchased: false), now: { now })
        await store.refresh()
        XCTAssertEqual(store.status, .expired)
        XCTAssertFalse(store.allowCut())
        XCTAssertTrue(store.showPaywall)

        let bought = LicenseStore(source: FakeSource(start: start, purchased: true), now: { now })
        await bought.refresh()
        XCTAssertEqual(bought.status, .purchased)
        XCTAssertTrue(bought.allowCut())
    }

    /// Closing the sheet frees the window slot, so the next opening goes to the then active window.
    @MainActor
    func testClosingPaywallReleasesHostWindow() {
        let now = day(8)
        let store = LicenseStore(source: FakeSource(start: start, purchased: false), now: { now })
        store.showPaywall = true
        store.paywallHost = UUID()
        store.showPaywall = false
        XCTAssertNil(store.paywallHost)
    }
}
