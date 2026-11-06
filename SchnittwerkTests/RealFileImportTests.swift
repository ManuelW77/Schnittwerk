// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
// Imports real files listed in SW_IMPORT_FILES (separated by "|"), for debugging.

import XCTest
@testable import Schnittwerk

final class RealFileImportTests: XCTestCase {
    func testImportRealFiles() throws {
        guard let list = ProcessInfo.processInfo.environment["SW_IMPORT_FILES"] else { throw XCTSkip("no SW_IMPORT_FILES") }
        for path in list.split(separator: "|").map(String.init) {
            let url = URL(fileURLWithPath: path)
            do {
                let (shape, warnings) = try ShapeImporter.importShape(from: url)
                print("IMPORT OK \(url.lastPathComponent): \(shape.paths.count) lines, size \(shape.size), warnings \(warnings)")
            } catch {
                print("IMPORT FAIL \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
