// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

#if APPSTORE
import SwiftUI

/// Sheet that offers the unlock purchase.
struct PaywallView: View {
    @Bindable var license: LicenseStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "scissors")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Unlock Schnittwerk").font(.title2.bold())
            Text(blurb)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = license.message {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            VStack(spacing: 8) {
                Button {
                    Task { await license.purchase() }
                } label: {
                    Text(buyTitle).frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(license.product == nil || license.busy)
                Button("Restore purchase") { Task { await license.restore() } }
                    .disabled(license.busy)
                Button("Close", role: .cancel) { license.showPaywall = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .task { await license.refresh() }
    }

    private var blurb: String {
        if license.status == .expired {
            String(localized: "The 7-day trial is over. You can still design, open and save projects. One purchase unlocks cutting for good.")
        } else {
            String(localized: "One purchase unlocks cutting for good. No subscription.")
        }
    }

    private var buyTitle: String {
        if let price = license.product?.displayPrice {
            String(localized: "Unlock for \(price)")
        } else {
            String(localized: "Unlock")
        }
    }
}

extension View {
    /// Hosts the purchase sheet; attach once to the window content.
    func licensePaywall() -> some View {
        modifier(PaywallModifier())
    }
}

private struct PaywallModifier: ViewModifier {
    @Bindable private var license = LicenseStore.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $license.showPaywall) { PaywallView(license: license) }
    }
}

/// Small trial note for the cut panel.
struct TrialNote: View {
    private let license = LicenseStore.shared

    var body: some View {
        switch license.status {
        case .trial(let days):
            Label("\(days) days of trial left", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .expired:
            Button { license.showPaywall = true } label: {
                Label("Trial over. Unlock cutting", systemImage: "lock")
            }
            .font(.caption)
        case .purchased:
            EmptyView()
        }
    }
}
#endif
