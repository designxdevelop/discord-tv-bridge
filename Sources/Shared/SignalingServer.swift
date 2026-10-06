import Foundation
import Network
import Darwin

/// Minimal HTTP/1.1 listener for WHEP signaling, advertised over Bonjour. One request per connection.
final class SignalingServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, _ peer: String) async -> HTTPResponse

    private let queue = DispatchQueue(label: "dev.designxdevelop.tvbridge.signaling")
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]  // confined to `queue`

    init(handler: @escaping Handler) { self.handler = handler }

    /// Starts listening; returns once the port is bound. `serviceName` nil disables Bonjour (tests).
    /// The TXT record carries this Mac's IPv4 so the TV can build a URL without resolving the service.
    func start(port: UInt16 = Signaling.port, serviceName: String?) async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        if let serviceName { listener.service = Self.service(serviceName, port: port) }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        self.listener = listener
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let serviceName, port == 0, let bound = listener.port {  // tests: advertise the ephemeral port
                        listener.service = Self.service(serviceName, port: bound.rawValue)
                    }
                    once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var port: UInt16? { listener?.port?.rawValue }

    private static func service(_ name: String, port: UInt16) -> NWListener.Service {
        var txt = NWTXTRecord()
        txt[Signaling.hostKey] = LocalNetwork.ipv4Address()
        txt[Signaling.portKey] = String(port)
        return NWListener.Service(name: name, type: Signaling.serviceType, txtRecord: txt)
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.close(key) }
        receive(connection, buffer: Data())
    }

    private func close(_ key: ObjectIdentifier) { connections.removeValue(forKey: key)?.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                let peer = Self.host(of: connection.endpoint)
                let server = self
                Task { [handler] in
                    let response = await handler(request, peer)
                    server.send(response, on: connection)
                }
            case .invalid(let status):
                self.send(.text(status, "Bad request."), on: connection)
            case .incomplete:
                if complete || error != nil { self.close(ObjectIdentifier(connection)) }
                else { self.receive(connection, buffer: buffer) }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { [weak self] _ in
            guard let server = self else { return }
            server.queue.async { server.close(ObjectIdentifier(connection)) }
        })
    }

    private static func host(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)".components(separatedBy: "%")[0] }
        return "\(endpoint)"
    }
}

/// Runs a closure at most once across threads (continuation guard).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        if first { body() }
    }
}

enum LocalNetwork {
    /// First IPv4 address on an "en" interface, for showing a manual-entry fallback address.
    static func ipv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var found: [(String, String)] = []
        var current = interfaces
        while let pointer = current {
            let interface = pointer.pointee
            current = interface.ifa_next
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.append((String(cString: interface.ifa_name), String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
            }
        }
        return found.first { $0.0 == "en0" }?.1 ?? found.first { $0.0.hasPrefix("en") }?.1
    }
}
