import Foundation

/// Local signaling follows WHEP (RFC 9725): the TV POSTs an SDP offer, the Mac answers with 201 + SDP.
/// Non-trickle ICE: both sides finish gathering before sending, so one round trip is enough.
enum Signaling {
    static let port: UInt16 = 8642
    static let serviceType = "_dtvbridge._tcp"
    static let hostKey = "host"
    static let portKey = "port"
    static let maxBodyBytes = 64 * 1024
    static let maxFailedAttempts = 10

    static func randomCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    /// Accepts "192.168.1.10", "192.168.1.10:8642", or a full http URL.
    static func baseURL(fromAddress text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var parts = URLComponents(string: candidate),
              parts.scheme?.lowercased() == "http", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        if parts.port == nil { parts.port = Int(port) }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }
}

struct HTTPRequest: Sendable, Equatable {
    var method: String
    var path: String
    var headers: [String: String]  // lowercased names
    var body: Data

    enum Parse: Equatable {
        case incomplete
        case invalid(status: Int)
        case complete(HTTPRequest)
    }

    static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 8192 ? .invalid(status: 431) : .incomplete
        }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid(status: 400) }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length: Int
        if let value = headers["content-length"] {
            guard let parsed = Int(value), parsed >= 0 else { return .invalid(status: 400) }
            length = parsed
        } else { length = 0 }
        guard length <= Signaling.maxBodyBytes else { return .invalid(status: 413) }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = Data(data[bodyStart..<(bodyStart + length)])
        let path = String(parts[1]).components(separatedBy: "?")[0]
        return .complete(HTTPRequest(method: String(parts[0]), path: path, headers: headers, body: body))
    }
}

struct HTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(message.utf8))
    }

    var serialized: Data {
        let reasons = [200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                       405: "Method Not Allowed", 413: "Content Too Large", 415: "Unsupported Media Type",
                       429: "Too Many Requests", 431: "Request Header Fields Too Large", 500: "Internal Server Error",
                       503: "Service Unavailable"]
        var lines = ["HTTP/1.1 \(status) \(reasons[status] ?? "Status")", "Content-Length: \(body.count)",
                     "Connection: close", "Cache-Control: no-store"]
        lines += headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }
}

/// Pairing gate + WHEP routes. The code is a bearer token; after too many wrong guesses all requests are
/// refused until sharing restarts with a fresh code.
actor WHEPEndpoint {
    typealias CreateSession = @Sendable (_ offer: String, _ peer: String) async throws -> (id: String, answer: String)
    typealias DeleteSession = @Sendable (_ id: String) async -> Bool

    nonisolated let code: String
    private let createSession: CreateSession
    private let deleteSession: DeleteSession
    private let onLockout: @Sendable () -> Void
    private(set) var failedAttempts = 0

    init(code: String, createSession: @escaping CreateSession, deleteSession: @escaping DeleteSession,
         onLockout: @escaping @Sendable () -> Void = {}) {
        self.code = code
        self.createSession = createSession
        self.deleteSession = deleteSession
        self.onLockout = onLockout
    }

    func respond(to request: HTTPRequest, peer: String = "") async -> HTTPResponse {
        guard failedAttempts < Signaling.maxFailedAttempts else {
            return .text(429, "Too many wrong pairing codes. Restart sharing on the Mac to get a new code.")
        }
        let components = request.path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, components[0].isEmpty, components[1] == "whep", components.count <= 3 else {
            return .text(404, "Not found.")
        }
        guard authorized(request.headers["authorization"]) else {
            failedAttempts += 1
            if failedAttempts == Signaling.maxFailedAttempts { onLockout() }
            return HTTPResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: Data("Wrong pairing code.".utf8))
        }
        switch (request.method, components.count) {
        case ("POST", 2):
            guard request.headers["content-type"]?.lowercased().hasPrefix("application/sdp") == true else {
                return .text(415, "Expected application/sdp.")
            }
            let offer = String(decoding: request.body, as: UTF8.self)
            guard offer.hasPrefix("v=0") else { return .text(400, "Body is not an SDP offer.") }
            do {
                let session = try await createSession(offer, peer)
                return HTTPResponse(status: 201, headers: ["Content-Type": "application/sdp", "Location": "/whep/\(session.id)"],
                                    body: Data(session.answer.utf8))
            } catch {
                return .text(503, error.localizedDescription)
            }
        case ("DELETE", 3):
            return await deleteSession(String(components[2])) ? HTTPResponse(status: 200) : .text(404, "No such session.")
        default:
            return .text(405, "Method not allowed.")
        }
    }

    private func authorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let presented = Array(header.dropFirst(7).utf8)
        let expected = Array(code.utf8)
        guard presented.count == expected.count else { return false }
        return zip(presented, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// TV-side client for the WHEP endpoint above.
struct WHEPClient: Sendable {
    let baseURL: URL
    let code: String

    enum Failure: LocalizedError, Equatable {
        case wrongCode, lockedOut, notSharing(String), unreachable(String), badResponse(Int)
        var errorDescription: String? {
            switch self {
            case .wrongCode: "Wrong pairing code. Check the six digits shown on your Mac."
            case .lockedOut: "Too many wrong codes. Stop and start sharing on the Mac for a new code."
            case .notSharing(let reason): "The Mac is not ready to share: \(reason)"
            case .unreachable(let reason): "Can't reach the Mac (\(reason)). Make sure sharing is on and both devices use the same network."
            case .badResponse(let status): "The Mac sent an unexpected reply (HTTP \(status))."
            }
        }
    }

    func exchange(offer: String) async throws -> (answer: String, session: URL) {
        var request = URLRequest(url: baseURL.appendingPathComponent("whep"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(offer.utf8)
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 201:
            guard let location = response.value(forHTTPHeaderField: "Location"),
                  let session = URL(string: location, relativeTo: baseURL)?.absoluteURL else { throw Failure.badResponse(201) }
            return (String(decoding: data, as: UTF8.self), session)
        case 401: throw Failure.wrongCode
        case 429: throw Failure.lockedOut
        case 503: throw Failure.notSharing(String(decoding: data, as: UTF8.self))
        default: throw Failure.badResponse(response.statusCode)
        }
    }

    /// Runs in its own task so a cancelled caller (Back during a handshake) still frees the Mac's session.
    func end(_ session: URL) async {
        var request = URLRequest(url: session, timeoutInterval: 3)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        await Task { _ = try? await send(request) }.value
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.badResponse(0) }
            return (data, http)
        } catch let error as Failure {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()  // URLSession reports task cancellation as URLError; callers must not show it
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
    }
}
