import Foundation
import Network
import Testing
@testable import BridgeCore

/// The TV finds the Mac via Bonjour and reads its address from the TXT record.
@Test(.timeLimit(.minutes(1))) func advertisesAddressInTXTRecord() async throws {
    let server = SignalingServer { _, _ in HTTPResponse(status: 404) }
    let name = "Discord TV Bridge test \(UUID().uuidString.prefix(6))"
    try await server.start(port: 0, serviceName: name)
    defer { server.stop() }
    let port = try #require(server.port)
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Signaling.serviceType, domain: nil), using: .tcp)
    let found: [String: String] = await withCheckedContinuation { continuation in
        let once = Once()
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case .service(name, _, _, _) = result.endpoint, case .bonjour(let txt) = result.metadata {
                    once.run { continuation.resume(returning: txt.dictionary) }
                }
            }
        }
        browser.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { once.run { continuation.resume(returning: [:]) } }
    }
    browser.cancel()
    #expect(found[Signaling.portKey] == String(port))
    #expect(found[Signaling.hostKey] == LocalNetwork.ipv4Address())
}
