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
    @State private var id = UUID()
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: isPresented) { PaywallView(license: license) }
            .onChange(of: license.showPaywall, initial: true) { _, show in
                guard show, license.paywallHost == nil else { return }
                if appearsActive {
                    // The active window takes the sheet right away
                    license.paywallHost = id
                } else {
                    // No active window (e.g. all minimized): the first one to get here takes it
                    DispatchQueue.main.async {
                        if license.showPaywall, license.paywallHost == nil { license.paywallHost = id }
                    }
                }
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { license.showPaywall && license.paywallHost == id },
            set: { if !$0, license.paywallHost == id { license.showPaywall = false } }
        )
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
