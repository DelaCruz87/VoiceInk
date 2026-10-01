// ENSO ad-hoc local override: VoiceInk Companion API v1 approved 2026-10-01 assumes a local,
// single-request HTTP/1.1 client on loopback. Network.framework or HTTP contract changes can make
// this stale; revalidate loopback binding, Host/auth checks, limits, and malformed-request tests.

import Foundation
import Network
import OSLog

struct CompanionHTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

struct CompanionHTTPResponse: Sendable {
    let statusCode: Int
    let contentType: String
    let body: Data
    let headers: [String: String]

    init(statusCode: Int, contentType: String = "application/json; charset=utf-8", body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
        self.headers = headers
    }
}

final class CompanionHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (CompanionHTTPRequest) async -> CompanionHTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.voiceink.companion.http", qos: .userInitiated)
    private let handler: Handler
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CompanionAPI")
    private let maxHeaderBytes = 32 * 1024
    private let maxBodyBytes = 1024 * 1024
    private let maxConnections = 32
    private let readDeadline: TimeInterval = 10
    private var activeConnections: Set<ObjectIdentifier> = []
    private var readingConnections: Set<ObjectIdentifier> = []

    init(port: UInt16, handler: @escaping Handler) throws {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw CompanionAPIError(status: "invalid_configuration", message: "Invalid companion port")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: networkPort)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start(
        onReady: @escaping @Sendable () -> Void = {},
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.notice("Companion API listening on loopback")
                onReady()
            case .failed(let error):
                self.logger.error("Companion API listener failed: \(error.localizedDescription, privacy: .public)")
                onFailure(error.localizedDescription)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard activeConnections.count < maxConnections else {
            connection.cancel()
            return
        }
        let identifier = ObjectIdentifier(connection)
        activeConnections.insert(identifier)
        readingConnections.insert(identifier)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async {
                    self?.activeConnections.remove(identifier)
                    self?.readingConnections.remove(identifier)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + readDeadline) { [weak self, weak connection] in
            guard let self, let connection, self.readingConnections.contains(identifier) else { return }
            self.send(self.errorResponse(408, "request_timeout", "Request headers or body timed out"), on: connection)
        }
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if buffer.count > self.maxHeaderBytes + self.maxBodyBytes {
                self.send(self.errorResponse(413, "request_too_large", "Request exceeds API limits"), on: connection)
                return
            }

            do {
                if let request = try self.parseIfComplete(buffer) {
                    self.readingConnections.remove(ObjectIdentifier(connection))
                    Task {
                        let response = await self.handler(request)
                        self.queue.async { self.send(response, on: connection) }
                    }
                    return
                }
            } catch let error as HTTPParseError {
                self.send(self.errorResponse(error.statusCode, error.status, error.message), on: connection)
                return
            } catch {
                self.send(self.errorResponse(400, "bad_request", "Malformed HTTP request"), on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, accumulated: buffer)
        }
    }

    private func parseIfComplete(_ data: Data) throws -> CompanionHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else {
            if data.count > maxHeaderBytes {
                throw HTTPParseError(431, "headers_too_large", "Request headers exceed API limits")
            }
            return nil
        }
        guard headerRange.lowerBound <= maxHeaderBytes else {
            throw HTTPParseError(431, "headers_too_large", "Request headers exceed API limits")
        }
        guard let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw HTTPParseError(400, "bad_request", "Request headers must be UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPParseError(400, "bad_request", "Missing request line")
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3, requestParts[2] == "HTTP/1.1" else {
            throw HTTPParseError(400, "bad_request", "Only HTTP/1.1 is supported")
        }
        let method = String(requestParts[0]).uppercased()
        guard method == "GET" || method == "POST" else {
            throw HTTPParseError(405, "method_not_allowed", "Only GET and POST are supported")
        }
        let target = String(requestParts[1])
        guard target.hasPrefix("/"), !target.contains("\\"), !target.contains("\0") else {
            throw HTTPParseError(400, "bad_request", "Invalid request target")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                throw HTTPParseError(400, "bad_request", "Malformed request header")
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else {
                throw HTTPParseError(400, "bad_request", "Duplicate or empty request header")
            }
            headers[key] = value
        }
        guard let host = headers["host"], Self.isAllowedHost(host) else {
            throw HTTPParseError(400, "invalid_host", "Host must be loopback")
        }
        if headers["transfer-encoding"] != nil {
            throw HTTPParseError(400, "unsupported_transfer_encoding", "Chunked requests are not supported")
        }
        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else {
                throw HTTPParseError(400, "bad_request", "Invalid Content-Length")
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        guard contentLength <= maxBodyBytes else {
            throw HTTPParseError(413, "request_too_large", "Request body exceeds API limits")
        }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return CompanionHTTPRequest(method: method, target: target, headers: headers, body: body)
    }

    private static func isAllowedHost(_ value: String) -> Bool {
        let normalized = value.lowercased()
        guard !normalized.contains("@"), !normalized.contains("/") else { return false }
        let host = normalized.split(separator: ":", maxSplits: 1).first.map(String.init) ?? normalized
        return host == "127.0.0.1" || host == "localhost"
    }

    private func send(_ response: CompanionHTTPResponse, on connection: NWConnection) {
        let reason = Self.reasonPhrase(for: response.statusCode)
        var lines = [
            "HTTP/1.1 \(response.statusCode) \(reason)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Cache-Control: no-store",
            "Connection: close",
        ]
        for (key, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        let header = Data(lines.joined(separator: "\r\n").utf8)
        connection.send(content: header, completion: .contentProcessed { error in
            guard error == nil else {
                connection.cancel()
                return
            }
            connection.send(content: response.body, completion: .contentProcessed { _ in connection.cancel() })
        })
    }

    private func errorResponse(_ code: Int, _ status: String, _ message: String) -> CompanionHTTPResponse {
        let body = (try? JSONEncoder.companion.encode(CompanionAPIError(status: status, message: message))) ?? Data()
        return CompanionHTTPResponse(statusCode: code, body: body)
    }

    private static func reasonPhrase(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Content"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}

private struct HTTPParseError: Error {
    let statusCode: Int
    let status: String
    let message: String

    init(_ statusCode: Int, _ status: String, _ message: String) {
        self.statusCode = statusCode
        self.status = status
        self.message = message
    }
}

extension JSONEncoder {
    static var companion: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var companion: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
