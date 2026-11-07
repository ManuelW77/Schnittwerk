// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Minimal HTTP/1.1 server for the MCP endpoint. Listens on the loopback
// interface only, reads one request per connection and closes it.

import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    /// Header names in lower case.
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
    }

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    func serialized() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        for (k, v) in all.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

final class LocalHTTPServer {
    typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    /// Larger requests are refused (an SVG of a few MB is plenty).
    static let maxRequestSize = 16 * 1024 * 1024

    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "schnittwerk.mcp.http")
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts listening on 127.0.0.1. `port` 0 picks a free port.
    /// `onState` reports readiness or failure on the main queue.
    func start(port: UInt16, onState: @escaping (Result<UInt16, Error>) -> Void) {
        stop()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                               port: NWEndpoint.Port(rawValue: port) ?? .any)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    let p = listener?.port?.rawValue ?? port
                    self?.port = p
                    DispatchQueue.main.async { onState(.success(p)) }
                case .failed(let error):
                    DispatchQueue.main.async { onState(.failure(error)) }
                    listener?.cancel()
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            DispatchQueue.main.async { onState(.failure(error)) }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestSize {
                self.send(.text(413, "Request too large"), on: connection)
                return
            }
            switch Self.parse(buffer) {
            case .complete(let request):
                self.handler(request) { response in self.send(response, on: connection) }
            case .invalid:
                self.send(.text(400, "Bad request"), on: connection)
            case .incomplete:
                if isComplete || error != nil { connection.cancel(); return }
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Parsing

    enum ParseResult {
        case complete(HTTPRequest)
        case incomplete
        case invalid
    }

    static func parse(_ buffer: Data) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        // Chunked bodies are not supported; MCP clients send Content-Length
        if headers["transfer-encoding"] != nil { return .invalid }
        let length: Int
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0, n <= maxRequestSize else { return .invalid }
            length = n
        } else {
            length = 0
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + length)]
        var path = String(requestLine[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return .complete(HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: Data(body)))
    }
}
