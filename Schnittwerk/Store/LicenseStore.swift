// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Mac App Store build: free download, 7 days with all functions, then one
// non-consumable in-app purchase unlocks cutting. The logic below compiles
// in every configuration (so it can be tested); the DMG build never uses it.
// Designing, opening and saving stay free after the trial.

import Foundation
import Observation
import OSLog
import StoreKit

enum LicenseStatus: Equatable {
    case trial(daysLeft: Int)
    case expired
    case purchased

    var canCut: Bool { self != .expired }
}

/// Pure trial rules, separate from StoreKit so tests can drive them.
enum TrialPolicy {
    static let days = 7

    /// - Parameter start: first download date (`AppTransaction.originalPurchaseDate`).
    ///   Unknown (nil) unlocks rather than locks: never lock a user out
    ///   because of a store hiccup.
    static func status(start: Date?, now: Date, purchased: Bool) -> LicenseStatus {
        if purchased { return .purchased }
        guard let start else { return .trial(daysLeft: days) }
        let elapsed = Int(floor(now.timeIntervalSince(start) / 86_400))
        if elapsed < 0 { return .trial(daysLeft: days) }  // clock set before the download date
        let left = days - elapsed
        return left > 0 ? .trial(daysLeft: left) : .expired
    }
}

/// Where the license facts come from; replaced in tests.
protocol LicenseSource: Sendable {
    /// First download date, nil when the store cannot tell.
    func trialStart() async -> Date?
    /// True if the unlock purchase is valid and not revoked.
    func hasPurchase() async -> Bool
    func product() async -> Product?
}

extension Logger {
    static let license = Logger(subsystem: "org.fire-devils.schnittwerk", category: "license")
}

struct StoreKitLicenseSource: LicenseSource {
    func trialStart() async -> Date? {
        do {
            switch try await AppTransaction.shared {
            case .verified(let t):
                return t.originalPurchaseDate
            case .unverified(let t, let error):
                // A signature problem is no proof of tampering: do not lock out.
                Logger.license.error("AppTransaction unverified: \(error.localizedDescription)")
                return t.originalPurchaseDate
            }
        } catch {
            Logger.license.error("AppTransaction unavailable, unlocking: \(error.localizedDescription)")
            return nil
        }
    }

    func hasPurchase() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == LicenseStore.productID, t.revocationDate == nil {
                return true
            }
        }
        return false
    }

    func product() async -> Product? {
        try? await Product.products(for: [LicenseStore.productID]).first
    }
}

@MainActor @Observable
final class LicenseStore {
    nonisolated static let productID = "org.fire-devils.schnittwerk.unlock"
    static let shared = LicenseStore()

    private(set) var status: LicenseStatus = .trial(daysLeft: TrialPolicy.days)
    private(set) var product: Product?
    private(set) var busy = false
    private(set) var message: String?
    /// Shows the purchase sheet.
    var showPaywall = false

    @ObservationIgnored private let source: LicenseSource
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(source: LicenseSource = StoreKitLicenseSource(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.now = now
    }

    var canCut: Bool { status.canCut }

    /// Called at app start: reads the state and watches for purchases made elsewhere.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let t) = update { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        let start = await source.trialStart()
        let purchased = await source.hasPurchase()
        status = TrialPolicy.status(start: start, now: now(), purchased: purchased)
        if product == nil { product = await source.product() }
    }

    /// True if cutting may go on; otherwise opens the purchase sheet.
    func allowCut() -> Bool {
        if canCut { return true }
        showPaywall = true
        return false
    }

    func purchase() async {
        guard let product else {
            message = String(localized: "The store is not available right now. Please try again later.")
            return
        }
        busy = true
        message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let t) = result {
                    await t.finish()
                    await refresh()
                    if status == .purchased { showPaywall = false }
                } else {
                    message = String(localized: "The purchase could not be verified.")
                }
            case .pending:
                message = String(localized: "The purchase is waiting for approval.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh()
            if status == .purchased { showPaywall = false }
            else { message = String(localized: "No earlier purchase was found.") }
        } catch {
            message = error.localizedDescription
        }
    }
}
