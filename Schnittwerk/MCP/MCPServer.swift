// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// MCP server (Model Context Protocol, Streamable HTTP transport).
// JSON-RPC requests arrive by POST at /mcp; responses are plain JSON.
// The server is off by default and only reachable from this Mac.

import Foundation
import SwiftUI

@MainActor
enum MCPProtocol {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// Handles one HTTP body (a JSON-RPC message or a batch).
    /// Calls `completion` with the response body, or nil for notifications only.
    static func handle(body: Data, context: @escaping () -> DocumentContext?,
                       completion: @escaping (Data?) -> Void) {
        guard let parsed = try? JSONSerialization.jsonObject(with: body) else {
            completion(encode(error(id: NSNull(), code: -32700, message: "Parse error")))
            return
        }
        if let batch = parsed as? [Any] {
            guard !batch.isEmpty else {
                completion(encode(error(id: NSNull(), code: -32600, message: "Invalid request")))
                return
            }
            var results: [[String: Any]?] = Array(repeating: nil, count: batch.count)
            var pending = batch.count
            for (i, item) in batch.enumerated() {
                handleMessage(item, context: context) { response in
                    results[i] = response
                    pending -= 1
                    if pending == 0 {
                        let list = results.compactMap { $0 }
                        completion(list.isEmpty ? nil : encode(list))
                    }
                }
            }
            return
        }
        handleMessage(parsed, context: context) { response in completion(response.map(encode)) }
    }

    private static func handleMessage(_ message: Any, context: @escaping () -> DocumentContext?,
                                      completion: @escaping ([String: Any]?) -> Void) {
        guard let msg = message as? [String: Any], msg["jsonrpc"] as? String == "2.0",
              let method = msg["method"] as? String else {
            let dict = message as? [String: Any]
            // Responses from the client need no answer (we send no requests)
            if let dict, dict["method"] == nil, dict["result"] != nil || dict["error"] != nil {
                completion(nil)
                return
            }
            completion(error(id: dict?["id"] ?? NSNull(), code: -32600, message: "Invalid request"))
            return
        }
        guard let id = msg["id"], !(id is NSNull) else {
            completion(nil) // notification, e.g. notifications/initialized
            return
        }
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = supportedVersions.contains(requested) ? requested : supportedVersions[0]
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            completion(result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "schnittwerk", "title": "Schnittwerk", "version": appVersion],
                "instructions": MCPTools.instructions,
            ]))
        case "ping":
            completion(result(id: id, [:]))
        case "tools/list":
            completion(result(id: id, ["tools": MCPTools.all.map(\.definition)]))
        case "tools/call":
            callTool(params, context: context) { completion(result(id: id, $0)) }
        default:
            completion(error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private static func callTool(_ params: [String: Any], context: @escaping () -> DocumentContext?,
                                 completion: @escaping ([String: Any]) -> Void) {
        func failure(_ text: String) -> [String: Any] {
            ["content": [MCPTools.text(text)], "isError": true]
        }
        guard let name = params["name"] as? String, let tool = MCPTools.tool(named: name) else {
            completion(failure("Unknown tool."))
            return
        }
        let args = ToolArgs(raw: params["arguments"] as? [String: Any] ?? [:])

        if name == "new_document" {
            DocumentRegistry.shared.openNewDocument()
            // The window registers itself once it is on screen
            waitForDocument(context: context, tries: 20) { _ in
                completion(["content": [MCPTools.text("A new window was opened.")]])
            }
            return
        }
        guard let ctx = context() else {
            completion(failure("No Schnittwerk project window is open. Call new_document first."))
            return
        }
        do {
            let content = try tool.run(args, ctx)
            completion(["content": content])
        } catch {
            completion(failure(error.localizedDescription))
        }
    }

    private static func waitForDocument(context: @escaping () -> DocumentContext?, tries: Int,
                                        done: @escaping (DocumentContext?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if tries <= 0 { done(context()); return }
            // A brand-new window becomes the most recently active one
            if let ctx = context(), ctx.document.data.shapes.isEmpty { done(ctx); return }
            waitForDocument(context: context, tries: tries - 1, done: done)
        }
    }

    static func result(id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    static func encode(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    }
}

/// Starts and stops the MCP server according to the settings.
@MainActor
final class MCPServerController: ObservableObject {
    static let shared = MCPServerController()
    static let defaultPort: UInt16 = 39170
    static let enabledKey = "mcp.enabled"
    static let portKey = "mcp.port"

    enum Status: Equatable {
        case off
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    private var server: LocalHTTPServer?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: Self.portKey)
        return (1024...65535).contains(p) ? UInt16(p) : Self.defaultPort
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    /// Applies the current settings (call after a change and at launch).
    func apply() {
        guard enabled else { stop(); return }
        start(port: port)
    }

    func start(port: UInt16, context: (() -> DocumentContext?)? = nil) {
        server?.stop()
        status = .starting
        let context = context ?? { DocumentRegistry.shared.current }
        let server = LocalHTTPServer { request, respond in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MCPServerController.route(request, context: context, respond: respond)
                }
            }
        }
        self.server = server
        server.start(port: port) { [weak self] result in
            switch result {
            case .success(let p): self?.status = .running(port: p)
            case .failure(let e): self?.status = .failed(e.localizedDescription)
            }
        }
    }

    func stop() {
        server?.stop()
        server = nil
        status = .off
    }

    // MARK: - HTTP

    /// Checks Host and Origin (protection against DNS rebinding: a web page
    /// in the browser must not be able to talk to the server) and hands
    /// POST /mcp to the protocol handler.
    static func route(_ request: HTTPRequest, context: @escaping () -> DocumentContext?,
                      respond: @escaping (HTTPResponse) -> Void) {
        guard request.path == "/mcp" else { respond(.text(404, "Not found")); return }
        guard isLocal(hostHeader: request.headers["host"]) else { respond(.text(403, "Forbidden host")); return }
        if let origin = request.headers["origin"], !isLocal(origin: origin) {
            respond(.text(403, "Forbidden origin"))
            return
        }
        guard request.method == "POST" else {
            // No server-to-client stream (GET) and no sessions (DELETE)
            var r = HTTPResponse.text(405, "Method not allowed")
            r.headers["Allow"] = "POST"
            respond(r)
            return
        }
        MCPProtocol.handle(body: request.body, context: context) { body in
            if let body { respond(.json(body)) } else { respond(HTTPResponse(status: 202)) }
        }
    }

    static func isLocal(hostHeader: String?) -> Bool {
        guard let host = hostHeader?.lowercased() else { return false }
        let name = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }) + "]"
                                        : String(host.split(separator: ":").first ?? "")
        return ["127.0.0.1", "localhost", "[::1]"].contains(name)
    }

    static func isLocal(origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }
}
