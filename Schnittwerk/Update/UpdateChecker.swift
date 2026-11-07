// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Looks for a newer Schnittwerk on GitHub Releases and tells the user.
// It only reads the public "latest release" of the repository; nothing
// about the user is sent. Installing stays with the user (download DMG).

import AppKit
import Foundation

/// A release as GitHub describes it (only the fields we need).
struct ReleaseInfo: Decodable, Equatable {
    let tagName: String
    let htmlURL: URL
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", name, body, draft, prerelease
    }

    /// "v0.2.0" → "0.2.0"
    var version: String {
        tagName.hasPrefix("v") || tagName.hasPrefix("V") ? String(tagName.dropFirst()) : tagName
    }
}

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True if `a` is a higher version than `b` ("0.10.0" > "0.9.1").
    /// Missing parts count as 0; anything after "-" is ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let core = v.split(separator: "-", maxSplits: 1).first.map(String.init) ?? v
            return core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let latestURL = URL(string: "https://api.github.com/repos/ManuelW77/Schnittwerk/releases/latest")!
    static let autoKey = "update.autoCheck"
    static let lastCheckKey = "update.lastCheck"
    static let skippedKey = "update.skippedVersion"
    /// Automatic checks at most this often.
    static let interval: TimeInterval = 24 * 60 * 60

    @Published private(set) var checking = false
    @Published private(set) var lastCheck: Date?

    private var timer: Timer?

    private init() {
        UserDefaults.standard.register(defaults: [Self.autoKey: true])
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    // MARK: - When to check

    /// Called at app start: checks now if due, then once a day.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
        // A moment after start, so the window is up first
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.checkIfDue() }
    }

    func checkIfDue() {
        guard UserDefaults.standard.bool(forKey: Self.autoKey) else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        check(userInitiated: false)
    }

    // MARK: - Checking

    /// With `userInitiated`, the user also hears "up to date" and errors,
    /// and a skipped version is shown again.
    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        Task {
            let result = await Self.fetchLatest()
            checking = false
            let now = Date()
            lastCheck = now
            UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
            switch result {
            case .success(let release):
                handle(release, userInitiated: userInitiated)
            case .failure(let error):
                if userInitiated { showError(error) }
            }
        }
    }

    /// Nil when the repository has no release yet.
    nonisolated static func fetchLatest() async -> Result<ReleaseInfo?, Error> {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Schnittwerk/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .success(nil) }
            guard status == 200 else { throw URLError(.badServerResponse) }
            return .success(try JSONDecoder().decode(ReleaseInfo.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    /// The release to tell the user about, if any.
    nonisolated static func offer(_ release: ReleaseInfo?, current: String, skipped: String?,
                                  userInitiated: Bool) -> ReleaseInfo? {
        guard let release, !release.draft, !release.prerelease,
              AppVersion.isNewer(release.version, than: current) else { return nil }
        if !userInitiated, release.version == skipped { return nil }
        return release
    }

    // MARK: - Telling the user

    private func handle(_ release: ReleaseInfo?, userInitiated: Bool) {
        let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
        guard let offer = Self.offer(release, current: AppVersion.current, skipped: skipped,
                                     userInitiated: userInitiated) else {
            if userInitiated { showUpToDate() }
            return
        }
        showUpdate(offer)
    }

    private func showUpdate(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Schnittwerk \(release.version) is available")
        var info = String(localized: "You have version \(AppVersion.current). Download the new version and drag it into Applications.")
        if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            let short = notes.count > 700 ? String(notes.prefix(700)) + " …" : notes
            info += "\n\n" + short
        }
        alert.informativeText = info
        alert.addButton(withTitle: String(localized: "Download"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "Skip this version"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        default:
            break
        }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Schnittwerk is up to date")
        alert.informativeText = String(localized: "Version \(AppVersion.current) is the newest version.")
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not check for updates")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
