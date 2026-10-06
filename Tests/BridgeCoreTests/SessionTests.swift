import Foundation
import Testing
import AudioToolbox
@preconcurrency import LiveKitWebRTC
@testable import BridgeCore

private let client = WHEPClient(baseURL: URL(string: "http://127.0.0.1:1")!, code: "123456")

@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
}

/// HTTP signaling succeeds every time but UDP media never connects: retries must stop, not loop forever.
@MainActor @Test func mediaFailuresAfterSignalingSuccessShareOneBoundedBudget() async {
    var connects = 0
    var disconnects = 0
    let session = ReceiverSession(connect: { _ in connects += 1 }, disconnect: { disconnects += 1 },
                                  retryDelay: .milliseconds(5), recoveryWait: .milliseconds(5))
    session.start(client)
    for round in 1...ReceiverSession.maxReconnects + 1 {
        await until { connects == round }
        #expect(connects == round)
        session.peerChanged(.connecting)
        session.peerChanged(.failed)
    }
    #expect(session.state == .failed(ReceiverSession.lostMessage))
    try? await Task.sleep(for: .milliseconds(100))
    #expect(connects == ReceiverSession.maxReconnects + 1)
    #expect(disconnects == ReceiverSession.maxReconnects + 1)  // between retries, and once at exhaustion

    // Only real media success refills the budget.
    session.retry()
    await until { connects == ReceiverSession.maxReconnects + 2 }
    session.peerChanged(.connected)
    #expect(session.state == .playing)
    session.peerChanged(.failed)
    #expect(session.state == .reconnecting(attempt: 1))
    session.stop()
}

/// A stuck "disconnected" connection also spends the budget instead of resetting it.
@MainActor @Test func unrecoveredDisconnectReconnects() async {
    var connects = 0
    let session = ReceiverSession(connect: { _ in connects += 1 }, disconnect: {},
                                  retryDelay: .milliseconds(5), recoveryWait: .milliseconds(5))
    session.start(client)
    await until { connects == 1 }
    session.peerChanged(.connected)
    session.peerChanged(.disconnected)
    #expect(session.state == .reconnecting(attempt: 0))
    await until { connects == 2 }
    #expect(session.state == .reconnecting(attempt: 1))
    session.stop()
}

/// Back/Cancel while a handshake is stuck: its late result can't revive the session or tear down a newer one.
@MainActor @Test func abandonedAttemptsCannotReviveOrTearDown() async {
    var gates: [CheckedContinuation<Void, Error>] = []
    var disconnects = 0
    let session = ReceiverSession(connect: { _ in try await withCheckedThrowingContinuation { gates.append($0) } },
                                  disconnect: { disconnects += 1 })
    session.start(client)
    await until { gates.count == 1 }
    session.stop()
    #expect(session.state == .setup)
    let afterStop = disconnects
    gates[0].resume(throwing: WHEPClient.Failure.unreachable("cancelled"))  // URLSession's late error
    try? await Task.sleep(for: .milliseconds(20))
    #expect(session.state == .setup)
    #expect(disconnects == afterStop)

    session.start(client)
    await until { gates.count == 2 }
    session.start(client)  // pressed Watch again
    await until { gates.count == 3 }
    let beforeStale = disconnects
    gates[1].resume(throwing: WHEPClient.Failure.notSharing("old"))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(session.state == .connecting)
    #expect(disconnects == beforeStale)
    gates[2].resume()
    session.peerChanged(.connected)
    #expect(session.state == .playing)
    session.stop()
}

@MainActor @Test func wrongCodeFailsWithoutRetrying() async {
    var connects = 0
    let session = ReceiverSession(connect: { _ in connects += 1; throw WHEPClient.Failure.wrongCode },
                                  disconnect: {}, retryDelay: .milliseconds(5))
    session.start(client)
    await until { session.state != .connecting }
    #expect(session.state == .failed(WHEPClient.Failure.wrongCode.localizedDescription))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(connects == 1)
}

/// URLSession reports a cancelled task as URLError.cancelled; callers must see CancellationError.
@Test(.timeLimit(.minutes(1))) func cancelledExchangeIsCancellationNotUnreachable() async throws {
    let server = SignalingServer { _, _ in
        try? await Task.sleep(for: .seconds(3))
        return HTTPResponse(status: 404)
    }
    try await server.start(port: 0, serviceName: nil)
    defer { server.stop() }
    let port = try #require(server.port)
    let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
    let request = Task { try await WHEPClient(baseURL: base, code: "123456").exchange(offer: "v=0") }
    try await Task.sleep(for: .milliseconds(200))
    request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }
}

@Test func audioScopeIncludesOnlyTheOwnerAndItsBundledHelpers() {
    let discord = "/Applications/Discord.app"
    func discordIncludes(_ id: String, _ path: String?) -> Bool {
        AudioScope.includes(bundleID: id, bundlePath: path, ownerID: "com.hnc.Discord", ownerPath: discord)
    }
    #expect(discordIncludes("com.hnc.Discord", discord))
    #expect(discordIncludes("com.hnc.Discord.helper", "\(discord)/Contents/Frameworks/Discord Helper.app"))
    #expect(discordIncludes("com.hnc.Discord.helper.Renderer", "\(discord)/Contents/Frameworks/Discord Helper (Renderer).app"))
    #expect(!discordIncludes("com.hnc.DiscordCanary", "/Applications/Discord Canary.app"))
    #expect(!discordIncludes("com.hnc.Discord.helper", "/Applications/Discord.app2/Helper.app"))  // not inside the owner
    #expect(!discordIncludes("com.hnc.Discord.helper", nil))
    #expect(!discordIncludes("com.spotify.client", "/Applications/Spotify.app"))
    #expect(!AudioScope.includes(bundleID: "com.vendor.AppBeta", bundlePath: "/Applications/AppBeta.app",
                                 ownerID: "com.vendor.App", ownerPath: "/Applications/App.app"))
    #expect(!AudioScope.includes(bundleID: "x", bundlePath: nil, ownerID: "", ownerPath: nil))
}

/// Stands in for WebRTC's audio device module and records every recorded-data delivery.
private final class FakeADM: NSObject, LKRTCAudioDeviceDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var threads = Set<UInt>()
    private var heard = false
    var count: Int { lock.withLock { calls } }
    var threadCount: Int { lock.withLock { threads.count } }
    var heardAudio: Bool { lock.withLock { heard } }

    var deliverRecordedData: LKRTCAudioDeviceDeliverRecordedDataBlock {
        { [self] _, _, _, frames, list, _, _ in
            let samples = list.map { UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: $0)) }?
                .first.map { UnsafeBufferPointer(start: $0.mData?.assumingMemoryBound(to: Int16.self), count: Int(frames)) }
            let loud = samples?.contains { $0 != 0 } ?? false
            lock.withLock {
                calls += 1
                threads.insert(UInt(bitPattern: pthread_self()))
                heard = heard || loud
            }
            return noErr
        }
    }
    var getPlayoutData: LKRTCAudioDeviceGetPlayoutDataBlock { { _, _, _, _, _ in noErr } }
    var preferredInputSampleRate: Double { 48_000 }
    var preferredInputIOBufferDuration: TimeInterval { 0.01 }
    var preferredOutputSampleRate: Double { 48_000 }
    var preferredOutputIOBufferDuration: TimeInterval { 0.01 }
    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}
    func dispatchAsync(_ block: @escaping () -> Void) { block() }
    func dispatchSync(_ block: () -> Void) { block() }
}

/// Stop/start (each viewer reconnect) and terminate/re-initialize keep one delivery thread, deliveries stop as
/// soon as stopRecording/terminateDevice return, and audio resumes afterwards.
@Test(.timeLimit(.minutes(1))) func audioDeviceKeepsOneThreadAndStopsCleanly() async throws {
    let device = PCMAudioDevice()
    let adm = FakeADM()
    #expect(device.initialize(with: adm))
    #expect(device.startRecording())
    device.enqueue(Array(repeating: 1_000, count: 4_800))
    try await Task.sleep(for: .milliseconds(150))
    #expect(device.stopRecording())
    #expect(!device.isRecording)
    let afterStop = adm.count
    #expect(afterStop > 5)
    #expect(adm.heardAudio)
    try await Task.sleep(for: .milliseconds(60))
    #expect(adm.count == afterStop)

    #expect(device.startRecording())
    try await Task.sleep(for: .milliseconds(100))
    #expect(adm.count > afterStop + 3)  // resumed
    #expect(device.terminateDevice())
    let afterTerminate = adm.count
    try await Task.sleep(for: .milliseconds(60))
    #expect(adm.count == afterTerminate)
    #expect(!device.startRecording())  // no delegate after terminate

    #expect(device.initialize(with: adm))
    #expect(device.startRecording())
    try await Task.sleep(for: .milliseconds(100))
    #expect(adm.count > afterTerminate + 3)
    #expect(device.terminateDevice())
    #expect(adm.threadCount == 1)
}
