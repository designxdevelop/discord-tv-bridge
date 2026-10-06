import Foundation
import CoreVideo
import Testing
@testable import BridgeCore

private func request(_ method: String, _ path: String, code: String? = "123456", body: String = "",
                     type: String? = "application/sdp") -> HTTPRequest {
    var headers: [String: String] = [:]
    if let code { headers["authorization"] = "Bearer \(code)" }
    if let type { headers["content-type"] = type }
    return HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
}

private func endpoint(onLockout: @escaping @Sendable () -> Void = {}) -> WHEPEndpoint {
    WHEPEndpoint(code: "123456", createSession: { offer, _ in ("abc", "v=0 answer for \(offer.count)") },
                 deleteSession: { $0 == "abc" }, onLockout: onLockout)
}

@Test func parsesRequestsIncrementally() {
    let raw = "POST /whep HTTP/1.1\r\nHost: x\r\nContent-Type: application/sdp\r\nContent-Length: 5\r\n\r\nv=0\r\n"
    #expect(HTTPRequest.parse(Data(raw.utf8).prefix(20)) == .incomplete)
    #expect(HTTPRequest.parse(Data(raw.utf8).dropLast(2)) == .incomplete)
    guard case .complete(let parsed) = HTTPRequest.parse(Data(raw.utf8)) else { Issue.record("not parsed"); return }
    #expect(parsed.method == "POST" && parsed.path == "/whep")
    #expect(parsed.headers["content-type"] == "application/sdp")
    #expect(parsed.body == Data("v=0\r\n".utf8))
    #expect(HTTPRequest.parse(Data("GARBAGE\r\n\r\n".utf8)) == .invalid(status: 400))
    #expect(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)) == .invalid(status: 413))
    #expect(HTTPRequest.parse(Data(repeating: 65, count: 9000)) == .invalid(status: 431))
}

@Test func serializesResponses() {
    let text = String(decoding: HTTPResponse.text(401, "no").serialized, as: UTF8.self)
    #expect(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\nContent-Length: 2\r\n"))
    #expect(text.hasSuffix("\r\n\r\nno"))
}

@Test func normalizesManualAddresses() {
    #expect(Signaling.baseURL(fromAddress: " 192.168.1.10 ")?.absoluteString == "http://192.168.1.10:8642")
    #expect(Signaling.baseURL(fromAddress: "192.168.1.10:9000")?.absoluteString == "http://192.168.1.10:9000")
    #expect(Signaling.baseURL(fromAddress: "http://mac.local:8642/whep?x")?.absoluteString == "http://mac.local:8642")
    #expect(Signaling.baseURL(fromAddress: "https://mac.local") == nil)
    #expect(Signaling.baseURL(fromAddress: "") == nil)
    #expect(Signaling.randomCode().count == 6)
}

@Test func whepRoutesRequireThePairingCode() async {
    let routes = endpoint()
    let created = await routes.respond(to: request("POST", "/whep", body: "v=0 offer"))
    #expect(created.status == 201)
    #expect(created.headers["Location"] == "/whep/abc")
    #expect(created.headers["Content-Type"] == "application/sdp")
    #expect(await routes.respond(to: request("POST", "/whep", code: "654321", body: "v=0")).status == 401)
    #expect(await routes.respond(to: request("POST", "/whep", code: nil, body: "v=0")).status == 401)
    #expect(await routes.respond(to: request("POST", "/whep", body: "v=0", type: "text/plain")).status == 415)
    #expect(await routes.respond(to: request("POST", "/whep", body: "hello")).status == 400)
    #expect(await routes.respond(to: request("GET", "/whep")).status == 405)
    #expect(await routes.respond(to: request("POST", "/other", body: "v=0")).status == 404)
    #expect(await routes.respond(to: request("DELETE", "/whep/abc")).status == 200)
    #expect(await routes.respond(to: request("DELETE", "/whep/zzz")).status == 404)
}

@Test func whepLocksOutAfterRepeatedWrongCodes() async {
    let locked = Once()
    nonisolated(unsafe) var lockouts = 0
    let routes = endpoint { locked.run { lockouts += 1 } }
    for _ in 0..<Signaling.maxFailedAttempts {
        #expect(await routes.respond(to: request("POST", "/whep", code: "000000", body: "v=0")).status == 401)
    }
    #expect(lockouts == 1)
    // Even the right code is refused now; sharing must restart with a new code.
    #expect(await routes.respond(to: request("POST", "/whep", body: "v=0")).status == 429)
}

@Test func whepClientMapsServerReplies() async throws {
    let server = SignalingServer { request, _ in
        request.headers["authorization"] == "Bearer 111111"
            ? HTTPResponse(status: 201, headers: ["Location": "/whep/s1"], body: Data("v=0 answer".utf8))
            : HTTPResponse(status: 401)
    }
    try await server.start(port: 0, serviceName: nil)
    defer { server.stop() }
    let port = try #require(server.port)
    let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
    let good = try await WHEPClient(baseURL: base, code: "111111").exchange(offer: "v=0")
    #expect(good.answer == "v=0 answer")
    #expect(good.session.absoluteString == base.absoluteString + "/whep/s1")
    await #expect(throws: WHEPClient.Failure.wrongCode) {
        try await WHEPClient(baseURL: base, code: "222222").exchange(offer: "v=0")
    }
    let closed = try #require(URL(string: "http://127.0.0.1:1"))
    await #expect(throws: WHEPClient.Failure.self) { try await WHEPClient(baseURL: closed, code: "1").exchange(offer: "v=0") }
}

@Test func downmixesFloatAudio() {
    let left: [Float] = [1, 0, -1, 2]
    let right: [Float] = [1, 0, 1, 2]
    let planar = left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in AudioConversion.monoInt16(channels: [l, r]) } }
    #expect(planar == [32_767, 0, 0, 32_767])
    let interleaved: [Float] = [0.5, 0.5, -0.5, -0.5]
    #expect(interleaved.withUnsafeBufferPointer { AudioConversion.monoInt16(channels: [$0], interleaved: 2) } == [16_383, -16_383])
}

@Test func demoPatternStampsReadableFrameIndex() throws {
    let pool = try #require(DemoPattern.makePool())
    for index in [0, 1, 777, 65_535] {
        let pixel = try #require(DemoPattern.frame(index, pool: pool))
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixel, 0)).assumingMemoryBound(to: UInt8.self)
        #expect(DemoPattern.readIndex(luma: luma, stride: CVPixelBufferGetBytesPerRowOfPlane(pixel, 0), width: DemoPattern.width) == index)
    }
}
