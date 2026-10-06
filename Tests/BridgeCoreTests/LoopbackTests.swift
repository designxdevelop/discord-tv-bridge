import Foundation
import Testing
@preconcurrency import LiveKitWebRTC
@testable import BridgeCore

/// Records which stamped demo frame each decoded frame was, and when.
private final class StampReader: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var received: [(index: Int, at: UInt64)] = []
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        let i420 = frame.buffer.toI420()
        let index = DemoPattern.readIndex(luma: i420.dataY, stride: Int(i420.strideY), width: Int(i420.width))
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock { received.append((index, now)) }
    }
    var snapshot: [(index: Int, at: UInt64)] { lock.withLock { received } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Int: UInt64] = [:]
    func mark(_ index: Int) { lock.withLock { sent[index] = DispatchTime.now().uptimeNanoseconds } }
    func sentAt(_ index: Int) -> UInt64? { lock.withLock { sent[index] } }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [(PeerState, UInt64)] = []
    func add(_ state: PeerState) { lock.withLock { states.append((state, DispatchTime.now().uptimeNanoseconds)) } }
    func first(_ match: (PeerState) -> Bool) -> UInt64? { lock.withLock { states.first { match($0.0) }?.1 } }
    var all: [PeerState] { lock.withLock { states.map(\.0) } }
}

/// Real end-to-end path on one Mac: demo frames → VideoToolbox H.264 → SRTP over loopback UDP →
/// jitter buffer → VideoToolbox decode, with WHEP signaling over the real HTTP server.
/// Latency excludes LAN transit and TV display/vsync; it's a floor for the pipeline, not glass-to-glass.
@Test(.serialized, .timeLimit(.minutes(1)), arguments: [nil, VideoCodec.h264])
func loopbackStreamsVideoAndAudioWithMeasuredLatency(codec: VideoCodec?) async throws {
    let publisher = Publisher()
    let viewerStates = StateLog()
    let publisherStates = StateLog()
    publisher.onViewerState = { _, state in publisherStates.add(state) }
    let routes = WHEPEndpoint(code: "424242",
                              createSession: { try await publisher.answer(offer: $0, peer: $1) },
                              deleteSession: { publisher.endViewer(id: $0) })
    let server = SignalingServer { await routes.respond(to: $0, peer: $1) }
    try await server.start(port: 0, serviceName: nil)
    defer { server.stop() }
    let port = try #require(server.port)

    let pool = try #require(DemoPattern.makePool())
    let clock = Clock()
    let feeder = Task.detached {
        var index = 0
        let ticks = ContinuousClock()
        var deadline = ticks.now
        while !Task.isCancelled {
            if let pixel = DemoPattern.frame(index & 0xFFFF, pool: pool) {
                clock.mark(index & 0xFFFF)
                publisher.push(pixel)
            }
            publisher.audio.enqueue(DemoPattern.tone(startingAt: index * 1_600, count: 1_600))
            index += 1
            deadline += .microseconds(33_333)
            try? await Task.sleep(until: deadline, clock: ticks)
        }
    }
    defer { feeder.cancel() }

    let viewer = Viewer(audioDevice: PCMAudioDevice())
    viewer.onState = { state, _ in viewerStates.add(state) }
    let reader = StampReader()
    viewer.setRenderer(reader)
    let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
    let started = DispatchTime.now().uptimeNanoseconds
    try await viewer.connect(WHEPClient(baseURL: base, code: "424242"), codec: codec)
    try await Task.sleep(for: .seconds(8))

    let stats = try #require(await viewer.stats())
    let connectedAt = try #require(viewerStates.first { $0 == .connected })
    let frames = reader.snapshot
    let firstFrame = try #require(frames.first)
    // Skip the first second (keyframe request, encoder ramp-up), then measure steady state.
    let latencies = frames.filter { $0.at > firstFrame.at + 1_000_000_000 }
        .compactMap { frame in clock.sentAt(frame.index).map { Double(frame.at - $0) / 1e6 } }
        .filter { $0 >= 0 && $0 < 2_000 }
        .sorted()
    let median = latencies.isEmpty ? -1 : latencies[latencies.count / 2]
    let p95 = latencies.isEmpty ? -1 : latencies[Int(Double(latencies.count - 1) * 0.95)]
    print("""
        LOOPBACK RESULT: \(stats.summary)
        connect (offer→connected): \(String(format: "%.0f", Double(connectedAt - started) / 1e6)) ms; \
        first frame after connect: \(String(format: "%.0f", Double(firstFrame.at - connectedAt) / 1e6)) ms
        capture→decoded latency over \(latencies.count) frames: median \(String(format: "%.1f", median)) ms, p95 \(String(format: "%.1f", p95)) ms
        """)
    #expect(stats.codec == (codec ?? .hevc).rawValue)
    #expect(stats.decoder == "VideoToolbox")
    #expect(stats.framesDecoded > 150)
    #expect(stats.audioPackets > 200)
    #expect(latencies.count > 150)  // ~7 s at 30 fps after warm-up
    #expect(median > 0 && median < 250)

    // Mac stops sharing: how quickly does the viewer notice without any extra signaling?
    let stopAt = DispatchTime.now().uptimeNanoseconds
    publisher.stop()
    try await Task.sleep(for: .seconds(2))
    let noticed = viewerStates.first { $0 == .failed || $0 == .disconnected || $0 == .closed }
    print("VIEWER after sender stop: states \(viewerStates.all.map(\.rawValue)); noticed in \(noticed.map { String(format: "%.1f ms", (Double($0) - Double(stopAt)) / 1e6) } ?? "> 2 s")")
    #expect(noticed.map { $0 >= stopAt } == true)

    // Reconnect to the same publisher: the audio device restarts recording on its one worker thread.
    try await viewer.connect(WHEPClient(baseURL: base, code: "424242"))
    try await Task.sleep(for: .seconds(3))
    let resumed = try #require(await viewer.stats())
    print("RECONNECT RESULT: \(resumed.summary)")
    #expect(resumed.audioPackets > 50)
    #expect(resumed.framesDecoded > 30)

    // TV disconnect path: DELETE removes the session on the Mac, and the Mac's UI hears about it.
    #expect(publisher.endViewer(id: "missing") == false)
    #expect(publisherStates.all.last == .connected)
    await viewer.disconnect().value
    #expect(publisherStates.all.last == .closed)
    #expect(publisher.endViewer() == false)
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// Publisher behind the real HTTP server. The `slow`-th offer (1-based) is answered, then its reply held back.
private func slowMac(slow: Int) async throws -> (Publisher, SignalingServer, URL, answered: Box<Int>, deleted: Box<[String]>) {
    let publisher = Publisher()
    let offers = Box(0)
    let deleted = Box<[String]>([])
    let routes = WHEPEndpoint(code: "123456", createSession: { offer, peer in
        let session = try await publisher.answer(offer: offer, peer: peer)
        offers.update { $0 += 1 }
        if offers.value == slow { try? await Task.sleep(for: .milliseconds(800)) }
        return session
    }, deleteSession: { id in
        deleted.update { $0.append(id) }
        return publisher.endViewer(id: id)
    })
    let server = SignalingServer { await routes.respond(to: $0, peer: $1) }
    try await server.start(port: 0, serviceName: nil)
    let port = try #require(server.port)
    let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
    return (publisher, server, base, offers, deleted)
}

private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
}

/// Back while the Mac is still answering: the abandoned attempt learns its session URL and deletes it.
@Test(.timeLimit(.minutes(1))) func backDuringHandshakeFreesTheMacSession() async throws {
    let (publisher, server, base, answered, deleted) = try await slowMac(slow: 1)
    defer { server.stop() }
    let viewer = Viewer(audioDevice: PCMAudioDevice())
    let attempt = Task { try await viewer.connect(WHEPClient(baseURL: base, code: "123456")) }
    try await waitFor { answered.value == 1 }  // the Mac has a viewer; its reply is still on the way
    attempt.cancel()
    viewer.disconnect()  // what ReceiverSession.stop does
    await #expect(throws: CancellationError.self) { try await attempt.value }
    #expect(deleted.value.count == 1)
    #expect(publisher.endViewer() == false)  // nothing left running on the Mac
}

/// A slow, superseded attempt cleans up only its own session; the newer connection keeps playing.
@Test(.timeLimit(.minutes(1))) func supersededAttemptLeavesTheNewerConnectionAlone() async throws {
    let (publisher, server, base, answered, deleted) = try await slowMac(slow: 1)
    defer { server.stop() }
    let viewer = Viewer(audioDevice: PCMAudioDevice())
    let connected = Box<[Int]>([])
    viewer.onState = { state, token in if state == .connected { connected.update { $0.append(token) } } }
    let client = WHEPClient(baseURL: base, code: "123456")
    let older = Task { try await viewer.connect(client) }
    try await waitFor { answered.value == 1 }
    try await viewer.connect(client)
    await #expect(throws: CancellationError.self) { try await older.value }
    try await Task.sleep(for: .seconds(1))
    #expect(deleted.value.count == 1)  // the older session only
    #expect(connected.value.contains { viewer.isCurrent($0) })
    #expect(publisher.endViewer())  // the newer viewer is still live on the Mac
}
