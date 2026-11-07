// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

@MainActor
final class MCPTests: XCTestCase {
    private var doc = CutDocument()
    private var selected: Set<UUID> = []

    private var context: DocumentContext {
        DocumentContext(document: doc, undoManager: nil) { [weak self] in self?.selected = $0 }
    }

    /// Sends one JSON-RPC request and returns the decoded response.
    private func rpc(_ method: String, _ params: [String: Any] = [:], id: Int = 1) -> [String: Any] {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        var out: [String: Any] = [:]
        let done = expectation(description: method)
        let ctx = context
        MCPProtocol.handle(body: body, context: { ctx }) { data in
            out = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return out
    }

    /// Calls a tool; returns (content, isError).
    private func call(_ name: String, _ args: [String: Any] = [:]) -> ([[String: Any]], Bool) {
        let r = rpc("tools/call", ["name": name, "arguments": args])["result"] as? [String: Any] ?? [:]
        return (r["content"] as? [[String: Any]] ?? [], r["isError"] as? Bool ?? false)
    }

    private func firstObject(_ content: [[String: Any]]) -> [String: Any] {
        let text = content.first?["text"] as? String ?? "[]"
        return ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]])?.first ?? [:]
    }

    // MARK: - Protocol

    func testInitializeEchoesKnownVersion() {
        let r = rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        let result = r["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
        XCTAssertNotNil(result?["instructions"])
    }

    func testToolsListHasSchemas() {
        let tools = (rpc("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, MCPTools.all.count)
        XCTAssertTrue(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        XCTAssertFalse(tools.contains { $0["name"] as? String == "cut" }, "no tool may start the plotter")
    }

    func testNotificationGetsNoResponse() {
        let body = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        var response: Data? = Data("x".utf8)
        MCPProtocol.handle(body: body, context: { nil }) { response = $0 }
        XCTAssertNil(response)
    }

    func testUnknownMethodAndParseError() {
        XCTAssertEqual((rpc("foo/bar")["error"] as? [String: Any])?["code"] as? Int, -32601)
        var out: [String: Any] = [:]
        MCPProtocol.handle(body: Data("{nope".utf8), context: { nil }) {
            out = (try? JSONSerialization.jsonObject(with: $0 ?? Data())) as? [String: Any] ?? [:]
        }
        XCTAssertEqual((out["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testNoWindowGivesToolError() {
        var out: [String: Any] = [:]
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                 "params": ["name": "get_document"]])
        MCPProtocol.handle(body: body, context: { nil }) {
            out = (try? JSONSerialization.jsonObject(with: $0 ?? Data())) as? [String: Any] ?? [:]
        }
        XCTAssertEqual((out["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    // MARK: - Tools

    func testAddShapeAndSelect() {
        let (content, isError) = call("add_shape", ["kind": "star", "width": 40, "height": 40, "x": 10, "y": 15, "sides": 6])
        XCTAssertFalse(isError)
        let obj = firstObject(content)
        XCTAssertEqual(obj["kind"] as? String, "star")
        XCTAssertEqual(obj["points"] as? Int, 6)
        XCTAssertEqual(obj["x"] as? Double ?? 0, 10, accuracy: 0.05)
        XCTAssertFalse((content.first?["text"] as? String ?? "").contains("9999"), "numbers are rounded")
        XCTAssertEqual(doc.data.shapes.count, 1)
        XCTAssertEqual(selected, [doc.data.shapes[0].id])
    }

    func testAddSVGScalesToWidth() {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="5mm" viewBox="0 0 10 5"><rect width="10" height="5"/></svg>"#
        let (content, isError) = call("add_svg", ["svg": svg, "width": 100, "x": 20, "y": 30, "name": "Box"])
        XCTAssertFalse(isError)
        let obj = firstObject(content)
        XCTAssertEqual(obj["width"] as? Double ?? 0, 100, accuracy: 0.05)
        XCTAssertEqual(obj["height"] as? Double ?? 0, 50, accuracy: 0.05)
        XCTAssertEqual(obj["name"] as? String, "Box")
    }

    func testAddSVGWithoutLinesIsError() {
        let (_, isError) = call("add_svg", ["svg": #"<svg xmlns="http://www.w3.org/2000/svg"><text>Hi</text></svg>"#])
        XCTAssertTrue(isError)
        XCTAssertTrue(doc.data.shapes.isEmpty)
    }

    func testAddTextWithFamilyName() {
        let (content, isError) = call("add_text", ["text": "Hallo", "font": "Helvetica", "size_mm": 30])
        XCTAssertFalse(isError)
        XCTAssertEqual(firstObject(content)["kind"] as? String, "text")
        XCTAssertEqual(firstObject(content)["font"] as? String, "Helvetica") // family → real face
        XCTAssertTrue(call("add_text", ["text": "x", "font": "NoSuchFont123"]).1)
    }

    func testUpdateObjectByNumber() {
        _ = call("add_shape", ["kind": "rectangle", "width": 20, "height": 10])
        let (content, isError) = call("update_object", ["id": "#1", "width": 60, "rotation": 90, "x": 5, "y": 5,
                                                         "corner_radius": 3, "cut": false])
        XCTAssertFalse(isError)
        let obj = firstObject(content)
        XCTAssertEqual(obj["width"] as? Double ?? 0, 60, accuracy: 0.05)
        XCTAssertEqual(obj["height"] as? Double ?? 0, 30, accuracy: 0.05) // proportions kept
        XCTAssertEqual(obj["corner_radius"] as? Double ?? 0, 3, accuracy: 0.05)
        XCTAssertEqual(obj["x"] as? Double ?? 0, 5, accuracy: 0.05)
        XCTAssertEqual(obj["cut"] as? Bool, false)
    }

    func testWrongArgumentsAreErrors() {
        _ = call("add_shape", ["kind": "rectangle"])
        XCTAssertTrue(call("update_object", ["id": "#9"]).1)
        XCTAssertTrue(call("update_object", ["id": "#1", "width": "wide"]).1)
        XCTAssertTrue(call("update_object", ["id": "#1", "text": "x"]).1) // not a text object
        XCTAssertTrue(call("add_shape", ["kind": "blob"]).1)
        XCTAssertTrue(call("no_such_tool").1)
        XCTAssertTrue(call("add_shape", ["kind": "polygon", "sides": 1e300]).1) // must not crash
    }

    func testCombineOffsetArrangeDelete() {
        _ = call("add_shape", ["kind": "rectangle", "width": 20, "height": 20, "x": 0, "y": 0])
        _ = call("add_shape", ["kind": "ellipse", "width": 20, "height": 20, "x": 10, "y": 10])
        XCTAssertFalse(call("combine", ["operation": "weld", "ids": ["#1", "#2"]]).1)
        XCTAssertEqual(doc.data.shapes.count, 1)
        XCTAssertFalse(call("add_offset", ["ids": ["#1"], "distance": 3]).1)
        XCTAssertEqual(doc.data.shapes.count, 2)
        XCTAssertFalse(call("arrange", ["ids": ["#2"], "action": "centerX"]).1)
        XCTAssertEqual(doc.data.shapes[1].matBounds.midX, doc.data.mat.displaySize.width / 2, accuracy: 0.05)
        XCTAssertFalse(call("delete_objects", ["ids": ["#1", "#2"]]).1)
        XCTAssertTrue(doc.data.shapes.isEmpty)
    }

    func testRenderPreviewReturnsPNG() {
        _ = call("add_shape", ["kind": "star"])
        let (content, isError) = call("render_preview", ["max_pixels": 400])
        XCTAssertFalse(isError)
        XCTAssertEqual(content.first?["mimeType"] as? String, "image/png")
        let png = Data(base64Encoded: content.first?["data"] as? String ?? "") ?? Data()
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        if let dir = ProcessInfo.processInfo.environment["SW_SNAPSHOT_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("mcp-preview.png"))
        }
    }

    func testChangesCanBeUndone() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let ctx = DocumentContext(document: doc, undoManager: undo, select: nil)
        undo.beginUndoGrouping()
        _ = try? MCPTools.tool(named: "add_shape")!.run(ToolArgs(raw: ["kind": "ellipse"]), ctx)
        undo.endUndoGrouping()
        XCTAssertEqual(doc.data.shapes.count, 1)
        undo.undo()
        XCTAssertTrue(doc.data.shapes.isEmpty)
    }
}

@MainActor
final class MCPHTTPTests: XCTestCase {
    func testHostAndOriginChecks() {
        XCTAssertTrue(MCPServerController.isLocal(hostHeader: "127.0.0.1:39170"))
        XCTAssertTrue(MCPServerController.isLocal(hostHeader: "localhost:1"))
        XCTAssertTrue(MCPServerController.isLocal(hostHeader: "[::1]:5"))
        XCTAssertFalse(MCPServerController.isLocal(hostHeader: "evil.example:39170"))
        XCTAssertFalse(MCPServerController.isLocal(hostHeader: "127.0.0.1.evil.example"))
        XCTAssertFalse(MCPServerController.isLocal(hostHeader: nil))
        XCTAssertTrue(MCPServerController.isLocal(origin: "http://localhost:3000"))
        XCTAssertFalse(MCPServerController.isLocal(origin: "https://evil.example"))
    }

    func testParserWaitsForBodyAndRefusesChunked() {
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 10\r\n\r\n"
        if case .incomplete = LocalHTTPServer.parse(Data((head + "12345").utf8)) {} else { XCTFail("expected incomplete") }
        if case .complete(let r) = LocalHTTPServer.parse(Data((head + "1234567890").utf8)) {
            XCTAssertEqual(r.body.count, 10)
            XCTAssertEqual(r.headers["host"], "127.0.0.1")
        } else { XCTFail("expected complete") }
        let chunked = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        if case .invalid = LocalHTTPServer.parse(Data(chunked.utf8)) {} else { XCTFail("expected invalid") }
    }

    /// Real HTTP round trip on a free port.
    func testServerAnswersOverHTTP() async throws {
        let doc = CutDocument()
        let controller = MCPServerController.shared
        let token = String(repeating: "ab", count: 32)
        controller.start(port: 0, token: token) { DocumentContext(document: doc, undoManager: nil, select: nil) }
        defer { controller.stop() }
        var port: UInt16 = 0
        for _ in 0..<50 {
            if case .running(let p) = controller.status { port = p; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotEqual(port, 0)

        func post(_ json: String, host: String? = nil, method: String = "POST", auth: String? = "Bearer " + token) async throws -> (Int, Data) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            req.httpMethod = method
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let host { req.setValue(host, forHTTPHeaderField: "Host") }
            if let auth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
            if method == "POST" { req.httpBody = Data(json.utf8) }
            let (data, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }

        let (status, data) = try await post(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_shape","arguments":{"kind":"ellipse"}}}"#)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("ellipse"))
        XCTAssertEqual(doc.data.shapes.count, 1)

        let (notify, _) = try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(notify, 202)
        let (get, _) = try await post("", method: "GET")
        XCTAssertEqual(get, 405)
        let (forbidden, _) = try await post(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, host: "evil.example")
        XCTAssertEqual(forbidden, 403)
        let (noToken, _) = try await post(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, auth: nil)
        XCTAssertEqual(noToken, 401)
        let (wrongToken, _) = try await post(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#, auth: "Bearer " + String(repeating: "cd", count: 32))
        XCTAssertEqual(wrongToken, 401)
    }

    func testTokenComparison() {
        XCTAssertTrue(MCPServerController.isAuthorized("Bearer abc", token: "abc"))
        XCTAssertTrue(MCPServerController.isAuthorized("bearer abc", token: "abc"))
        XCTAssertFalse(MCPServerController.isAuthorized("Bearer abd", token: "abc"))
        XCTAssertFalse(MCPServerController.isAuthorized("Bearer ab", token: "abc"))
        XCTAssertFalse(MCPServerController.isAuthorized("abc", token: "abc"))
        XCTAssertFalse(MCPServerController.isAuthorized(nil, token: "abc"))
        XCTAssertFalse(MCPServerController.isAuthorized("Bearer ", token: ""))
    }
}
