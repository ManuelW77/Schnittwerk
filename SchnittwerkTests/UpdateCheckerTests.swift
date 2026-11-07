// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class UpdateCheckerTests: XCTestCase {
    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> ReleaseInfo {
        ReleaseInfo(tagName: tag, htmlURL: URL(string: "https://github.com/ManuelW77/Schnittwerk/releases/tag/\(tag)")!,
                    name: nil, body: nil, draft: draft, prerelease: prerelease)
    }

    func testVersionCompare() {
        XCTAssertTrue(AppVersion.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(AppVersion.isNewer("0.10.0", than: "0.9.1"), "numbers, not text")
        XCTAssertTrue(AppVersion.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(AppVersion.isNewer("0.1.1", than: "0.1"))
        XCTAssertFalse(AppVersion.isNewer("0.1.0", than: "0.1"))
        XCTAssertFalse(AppVersion.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(AppVersion.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(AppVersion.isNewer("0.2.0-beta", than: "0.2.0"))
    }

    func testTagPrefixIsDropped() {
        XCTAssertEqual(release("v0.2.0").version, "0.2.0")
        XCTAssertEqual(release("0.2.0").version, "0.2.0")
    }

    func testOffer() {
        XCTAssertEqual(UpdateChecker.offer(release("v0.2.0"), current: "0.1.0", skipped: nil, userInitiated: false)?.version, "0.2.0")
        XCTAssertNil(UpdateChecker.offer(release("v0.1.0"), current: "0.1.0", skipped: nil, userInitiated: true))
        XCTAssertNil(UpdateChecker.offer(nil, current: "0.1.0", skipped: nil, userInitiated: true), "no release yet")
        XCTAssertNil(UpdateChecker.offer(release("v0.2.0", draft: true), current: "0.1.0", skipped: nil, userInitiated: true))
        XCTAssertNil(UpdateChecker.offer(release("v0.2.0", prerelease: true), current: "0.1.0", skipped: nil, userInitiated: true))
    }

    func testSkippedVersionOnlyComesBackWhenAsked() {
        let r = release("v0.2.0")
        XCTAssertNil(UpdateChecker.offer(r, current: "0.1.0", skipped: "0.2.0", userInitiated: false))
        XCTAssertNotNil(UpdateChecker.offer(r, current: "0.1.0", skipped: "0.2.0", userInitiated: true))
        XCTAssertNotNil(UpdateChecker.offer(release("v0.3.0"), current: "0.1.0", skipped: "0.2.0", userInitiated: false))
    }

    func testDecodesGitHubJSON() throws {
        let json = """
        {"tag_name":"v0.2.0","html_url":"https://github.com/ManuelW77/Schnittwerk/releases/tag/v0.2.0",
         "name":"Schnittwerk 0.2.0","body":"- Neu","draft":false,"prerelease":false,"assets":[]}
        """
        let r = try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
        XCTAssertEqual(r.version, "0.2.0")
        XCTAssertEqual(r.body, "- Neu")
    }
}
