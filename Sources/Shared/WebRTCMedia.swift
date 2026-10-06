import Foundation
import CoreVideo
import AudioToolbox
@preconcurrency import LiveKitWebRTC

enum WebRTCRuntime {
    /// Must run once before any factory is created.
    static let setUp: Void = { _ = LKRTCInitializeSSL() }()

    static func configuration() -> LKRTCConfiguration {
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherOnce
        config.iceServers = []  // ponytail: LAN only; add STUN/TURN servers here for routed networks.
        return config
    }

    static let noConstraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    /// Non-trickle ICE: wait until host candidates are in the local description (milliseconds on a LAN).
    static func waitForGathering(_ connection: LKRTCPeerConnection, timeout: Duration = .seconds(3)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while connection.iceGatheringState != .complete, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// VideoToolbox-only codecs, HEVC preferred, H.264 fallback. VP8/VP9/AV1 are excluded so negotiation can
/// never land on a software codec on Apple TV.
enum VideoCodec: String, Sendable, CaseIterable {
    case hevc = "H265", h264 = "H264"
}

final class HardwareEncoderFactory: NSObject, LKRTCVideoEncoderFactory {
    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        [LKRTCVideoCodecInfo(name: VideoCodec.hevc.rawValue)] + LKRTCVideoEncoderFactoryH264().supportedCodecs()
    }

    func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
        switch info.name {
        case VideoCodec.hevc.rawValue: LKRTCVideoEncoderH265(codecInfo: info)
        case VideoCodec.h264.rawValue: LKRTCVideoEncoderH264(codecInfo: info)
        default: nil
        }
    }
}

final class HardwareDecoderFactory: NSObject, LKRTCVideoDecoderFactory {
    private let base = LKRTCDefaultVideoDecoderFactory()

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        let all = base.supportedCodecs()
        return VideoCodec.allCases.flatMap { codec in all.filter { $0.name == codec.rawValue } }
    }

    func createDecoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoDecoder)? {
        VideoCodec(rawValue: info.name) == nil ? nil : base.createDecoder(info)
    }
}

enum MediaError: LocalizedError {
    case peerConnection, noLocalDescription, superseded, connectionLost
    var errorDescription: String? {
        switch self {
        case .peerConnection: "WebRTC could not create a peer connection."
        case .noLocalDescription: "WebRTC did not produce a session description."
        case .superseded: "A newer connection from the TV replaced this one."
        case .connectionLost: "The media connection to your Mac failed."
        }
    }
}

/// Simple connection state mirrored from WebRTC for UI code.
enum PeerState: String, Sendable {
    case new, connecting, connected, disconnected, failed, closed

    init(_ state: LKRTCPeerConnectionState) {
        switch state {
        case .new: self = .new
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .disconnected: self = .disconnected
        case .failed: self = .failed
        case .closed: self = .closed
        @unknown default: self = .failed
        }
    }
}

// MARK: - Sender (Mac)

/// One send-only video + audio source shared by at most one viewer at a time. HEVC or H.264 (VideoToolbox).
/// State guarded by `lock`; WebRTC calls the delegate on its signaling thread.
final class Publisher: NSObject, LKRTCPeerConnectionDelegate, @unchecked Sendable {
    let audio = PCMAudioDevice()
    /// Current viewer's state, `.closed` once it is ended (DELETE or stop). Called with the lock held so events
    /// stay ordered; must not block or call back into the publisher. Set before the first `answer`.
    var onViewerState: (@Sendable (_ peer: String, _ state: PeerState) -> Void)?

    private let factory: LKRTCPeerConnectionFactory
    private let videoSource: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer
    private let videoTrack: LKRTCVideoTrack
    private let audioTrack: LKRTCAudioTrack
    private let maxBitrate: Int
    private let lock = NSLock()
    private var viewer: (id: String, connection: LKRTCPeerConnection, peer: String)?
    private var latestOffer = 0  // only the newest in-flight answer may become the viewer

    init(maxBitrate: Int = 8_000_000) {
        WebRTCRuntime.setUp
        self.maxBitrate = maxBitrate
        factory = LKRTCPeerConnectionFactory(encoderFactory: HardwareEncoderFactory(),
                                             decoderFactory: HardwareDecoderFactory(), audioDevice: audio)
        videoSource = factory.videoSource(forScreenCast: true)
        capturer = LKRTCVideoCapturer(delegate: videoSource)
        videoTrack = factory.videoTrack(with: videoSource, trackId: "screen")
        audioTrack = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "app-audio")
        super.init()
        // App/game/call audio is not a microphone: no echo cancellation, noise suppression or AGC.
        _ = audioTrack.setAudioProcessingOptions(LKRTCAudioProcessingOptions.raw())
    }

    func push(_ pixelBuffer: CVPixelBuffer, timeNs: Int64 = Int64(DispatchTime.now().uptimeNanoseconds)) {
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: timeNs)
        videoSource.capturer(capturer, didCapture: frame)
    }

    /// Answers a viewer's offer. A new viewer replaces the previous one (single TV, simple reconnects).
    func answer(offer: String, peer: String) async throws -> (id: String, answer: String) {
        let ticket = lock.withLock { latestOffer += 1; return latestOffer }
        guard let connection = factory.peerConnection(with: WebRTCRuntime.configuration(),
                                                      constraints: WebRTCRuntime.noConstraints, delegate: self) else {
            throw MediaError.peerConnection
        }
        do {
            try await connection.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: offer))
            // Attaches to the offer's recvonly transceivers, making them sendonly on our side.
            connection.add(videoTrack, streamIds: ["screen"])
            connection.add(audioTrack, streamIds: ["screen"])
            let answer = try await connection.answer(for: WebRTCRuntime.noConstraints)
            try await connection.setLocalDescription(answer)
            if let sender = connection.senders.first(where: { $0.track?.kind == kLKRTCMediaStreamTrackKindVideo }) {
                let parameters = sender.parameters
                parameters.encodings.forEach { $0.maxBitrateBps = NSNumber(value: maxBitrate) }
                sender.parameters = parameters
            }
            await WebRTCRuntime.waitForGathering(connection)
            guard let sdp = connection.localDescription?.sdp else { throw MediaError.noLocalDescription }
            let id = UUID().uuidString.lowercased()
            let previous = try lock.withLock { () throws -> LKRTCPeerConnection? in
                guard ticket == latestOffer else { throw MediaError.superseded }  // a newer offer or stop() won
                defer { viewer = (id, connection, peer) }
                return viewer?.connection  // replaced silently: the new viewer's own states follow
            }
            previous?.close()
            return (id, sdp)
        } catch {
            connection.close()
            throw error
        }
    }

    @discardableResult
    func endViewer(id: String? = nil) -> Bool {
        let ended = lock.withLock { () -> LKRTCPeerConnection? in
            guard let current = viewer, id == nil || current.id == id else { return nil }
            viewer = nil
            onViewerState?(current.peer, .closed)  // close() below is not reported: the delegate ignores ex-viewers
            return current.connection
        }
        ended?.close()
        return ended != nil
    }

    func stop() {
        lock.withLock { latestOffer += 1 }  // answers still in flight must not install a viewer afterwards
        endViewer()
        audio.reset()
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        lock.withLock {
            guard let viewer, viewer.connection === peerConnection else { return }
            onViewerState?(viewer.peer, PeerState(newState))
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}

// MARK: - Receiver (Apple TV)

struct ViewerStats: Sendable, Equatable {
    var codec = ""
    var decoder = ""
    var width = 0
    var height = 0
    var framesPerSecond = 0.0
    var framesDecoded = 0
    var jitterBufferMs = 0.0
    var roundTripMs = 0.0
    var audioPackets = 0
    var packetsLost = 0

    var summary: String {
        let size = width > 0 ? "\(width)×\(height)" : "no video yet"
        return String(format: "%@ %@ · %.0f fps · decoder %@ · jitter buffer %.0f ms · RTT %.0f ms · audio packets %d · lost %d",
                      codec, size, framesPerSecond, decoder.isEmpty ? "?" : decoder, jitterBufferMs, roundTripMs, audioPackets, packetsLost)
    }
}

/// Receive-only peer. Creates the offer (HEVC/H.264 video + Opus audio) and exchanges it via WHEP.
/// Each `connect` owns a token; a superseded or disconnected attempt cleans up only its own connection and session.
final class Viewer: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate, @unchecked Sendable {
    /// State of the connection identified by `token`; compare with `isCurrent` after hopping threads.
    var onState: (@Sendable (_ state: PeerState, _ token: Int) -> Void)?

    private let factory: LKRTCPeerConnectionFactory
    private let lock = NSLock()
    private var token = 0
    private var connection: LKRTCPeerConnection?
    private var session: (client: WHEPClient, url: URL)?
    private var renderer: LKRTCVideoRenderer?
    private var videoTrack: LKRTCVideoTrack?  // the ObjC wrapper drops its renderers when deallocated
    private var control: LKRTCDataChannel?  // closes within milliseconds when the Mac stops; ICE would take seconds

    /// `audioDevice` lets tests run without speakers; the TV uses the AVAudioEngine-based device module.
    init(audioDevice: LKRTCAudioDevice? = nil) {
        WebRTCRuntime.setUp
        let decoders = HardwareDecoderFactory()
        #if os(tvOS)
        if audioDevice == nil {
            factory = LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine, bypassVoiceProcessing: true,
                                                 encoderFactory: nil, decoderFactory: decoders, audioProcessingModule: nil)
        } else {
            factory = LKRTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: decoders, audioDevice: audioDevice)
        }
        #else
        factory = LKRTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: decoders, audioDevice: audioDevice)
        #endif
        super.init()
    }

    /// The renderer is attached to every new video track (e.g. an `LKRTCMTLVideoView`).
    func setRenderer(_ renderer: LKRTCVideoRenderer?) { lock.withLock { self.renderer = renderer } }

    func isCurrent(_ token: Int) -> Bool { lock.withLock { self.token == token && connection != nil } }

    /// `codec` restricts the offer to one codec; nil offers HEVC first with H.264 fallback.
    /// Throws `CancellationError` if `disconnect` or a newer `connect` took over meanwhile.
    func connect(_ client: WHEPClient, codec: VideoCodec? = nil) async throws {
        disconnect()
        guard let connection = factory.peerConnection(with: WebRTCRuntime.configuration(),
                                                      constraints: WebRTCRuntime.noConstraints, delegate: self) else {
            throw MediaError.peerConnection
        }
        let receiveOnly = LKRTCRtpTransceiverInit()
        receiveOnly.direction = .recvOnly
        let video = connection.addTransceiver(of: .video, init: receiveOnly)
        _ = connection.addTransceiver(of: .audio, init: receiveOnly)
        let control = connection.dataChannel(forLabel: "control", configuration: LKRTCDataChannelConfiguration())
        control?.delegate = self
        if let codec, let video {
            let capabilities = factory.rtpReceiverCapabilities(forKind: kLKRTCMediaStreamTrackKindVideo).codecs
            // Keep RTX/RED/FEC entries; drop the other primary codec.
            let preferred = capabilities.filter { $0.name == codec.rawValue || VideoCodec(rawValue: $0.name) == nil }
            // Swift imports the throwing variant with a Void `error:` label because of the deprecated overload.
            do { try video.setCodecPreferences(preferred, error: ()) } catch { connection.close(); throw error }
        }
        let mine = lock.withLock { () -> Int in
            token += 1
            self.connection = connection
            self.control = control
            return token
        }
        /// Runs `commit` only while this attempt still owns the viewer.
        func owned<T>(_ commit: () -> T) throws -> T {
            try lock.withLock {
                guard token == mine, !Task.isCancelled else { throw CancellationError() }
                return commit()
            }
        }
        var created: URL?
        do {
            let offer = try await connection.offer(for: WebRTCRuntime.noConstraints)
            try await connection.setLocalDescription(offer)
            await WebRTCRuntime.waitForGathering(connection)
            guard let sdp = connection.localDescription?.sdp else { throw MediaError.noLocalDescription }
            try owned {}
            // Not cancelled with the caller: if Back is pressed mid-request we still learn the session URL and delete it.
            let (answer, url) = try await Task { try await client.exchange(offer: sdp) }.value
            created = url
            try owned { session = (client, url) }
            try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: answer))
            try owned {}
            // Claim the track atomically with the ownership check, attach outside the lock, then re-check:
            // a disconnect or newer connect in between must not keep the renderer on this stale track.
            if let track = video?.receiver.track as? LKRTCVideoTrack,
               let renderer = try owned({ () -> LKRTCVideoRenderer? in videoTrack = track; return renderer }) {
                track.add(renderer)
                do { try owned {} } catch { track.remove(renderer); throw error }
            }
        } catch {
            let stillMine = lock.withLock { () -> Bool in
                guard token == mine else { return false }
                token += 1
                self.connection = nil; self.session = nil; self.videoTrack = nil; self.control = nil
                return true
            }
            connection.close()
            if let created { await client.end(created) }
            throw stillMine ? error : CancellationError()
        }
    }

    /// Synchronously detaches and closes the current connection; the returned task tells the Mac (best effort)
    /// so it can show the TV as gone immediately.
    @discardableResult
    func disconnect() -> Task<Void, Never> {
        let (connection, session) = lock.withLock { () -> (LKRTCPeerConnection?, (client: WHEPClient, url: URL)?) in
            defer { token += 1; self.connection = nil; self.session = nil; self.videoTrack = nil; self.control = nil }
            return (self.connection, self.session)
        }
        connection?.close()
        return Task { if let session { await session.client.end(session.url) } }
    }

    func stats() async -> ViewerStats? {
        guard let connection = lock.withLock({ self.connection }) else { return nil }
        let report = await connection.statistics()
        var stats = ViewerStats()
        var codecs: [String: String] = [:]
        for item in report.statistics.values where item.type == "codec" {
            codecs[item.id] = (item.values["mimeType"] as? String)?.components(separatedBy: "/").last
        }
        for item in report.statistics.values {
            let values = item.values
            func number(_ key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
            switch item.type {
            case "inbound-rtp" where values["kind"] as? String == "video":
                stats.codec = codecs[values["codecId"] as? String ?? ""] ?? ""
                stats.decoder = values["decoderImplementation"] as? String ?? ""
                stats.width = Int(number("frameWidth"))
                stats.height = Int(number("frameHeight"))
                stats.framesPerSecond = number("framesPerSecond")
                stats.framesDecoded = Int(number("framesDecoded"))
                let emitted = number("jitterBufferEmittedCount")
                stats.jitterBufferMs = emitted > 0 ? number("jitterBufferDelay") / emitted * 1000 : 0
                stats.packetsLost += Int(number("packetsLost"))
            case "inbound-rtp" where values["kind"] as? String == "audio":
                stats.audioPackets = Int(number("packetsReceived"))
                stats.packetsLost += Int(number("packetsLost"))
            case "candidate-pair" where values["nominated"] as? Bool == true && values["state"] as? String == "succeeded":
                stats.roundTripMs = number("currentRoundTripTime") * 1000
            default: break
            }
        }
        return stats
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        guard let token = lock.withLock({ connection === peerConnection ? token : nil }) else { return }
        onState?(PeerState(newState), token)
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        guard dataChannel.readyState == .closed,
              let token = lock.withLock({ control === dataChannel ? token : nil }) else { return }
        onState?(.closed, token)
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}

// MARK: - Audio

/// Custom WebRTC audio device: recording is fed from captured app audio (never a microphone),
/// playout is a no-op. Mono 48 kHz Int16, paced in 10 ms chunks by one worker thread that lives as long as the
/// device, so WebRTC always receives recorded data on the same thread (RTCAudioDevice.h) and no interruption
/// notification is ever needed. `stopRecording`/`terminateDevice` return only after any in-flight delivery ends.
final class PCMAudioDevice: NSObject, LKRTCAudioDevice, @unchecked Sendable {
    static let sampleRate = 48_000
    static let chunk = 480
    private static let maxBuffered = 9_600  // ponytail: 200 ms cap bounds latency; oldest audio is dropped

    private let condition = NSCondition()  // guards the state below
    private var pending: [Int16] = []
    private var delegate: LKRTCAudioDeviceDelegate?
    private var deliver: LKRTCAudioDeviceDeliverRecordedDataBlock?  // non-nil while recording
    private var delivering = false
    private var worker: Thread?
    private var flags = (initialized: false, playoutInitialized: false, playing: false, recordingInitialized: false)
    // Worker thread only.
    private var buffer = [Int16](repeating: 0, count: chunk)
    private var sampleTime = 0.0
    private var nextTick: UInt64 = 0

    /// Appends mono 48 kHz samples from capture (any thread).
    func enqueue(_ samples: [Int16]) {
        locked {
            pending += samples
            if pending.count > Self.maxBuffered { pending.removeFirst(pending.count - Self.maxBuffered) }
        }
    }

    func reset() { locked { pending.removeAll() } }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        condition.lock()
        defer { condition.unlock() }
        return try body()
    }

    var deviceInputSampleRate: Double { Double(Self.sampleRate) }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Double(Self.sampleRate) }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { 0 }
    var isInitialized: Bool { locked { flags.initialized } }
    var isPlayoutInitialized: Bool { locked { flags.playoutInitialized } }
    var isPlaying: Bool { locked { flags.playing } }
    var isRecordingInitialized: Bool { locked { flags.recordingInitialized } }
    var isRecording: Bool { locked { deliver != nil } }

    func initialize(with delegate: LKRTCAudioDeviceDelegate) -> Bool {
        locked { self.delegate = delegate; flags.initialized = true }
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopRecording()
        locked { delegate = nil; flags = (false, false, false, false) }
        return true
    }

    func initializePlayout() -> Bool { locked { flags.playoutInitialized = true }; return true }
    func startPlayout() -> Bool { locked { flags.playing = true }; return true }
    func stopPlayout() -> Bool { locked { flags.playing = false }; return true }
    func initializeRecording() -> Bool { locked { flags.recordingInitialized = true }; return true }

    func startRecording() -> Bool {
        locked {
            guard let delegate else { return false }
            if deliver == nil { pending.removeAll() }
            deliver = delegate.deliverRecordedData
            if worker == nil {
                // Weak, re-taken each iteration, so the thread ends once the device is released.
                let thread = Thread { [weak self] in while let self { self.step() } }
                thread.name = "PCMAudioDevice"
                thread.qualityOfService = .userInteractive
                worker = thread
                thread.start()
            }
            condition.broadcast()
            return true
        }
    }

    func stopRecording() -> Bool {
        locked {
            deliver = nil
            while delivering { condition.wait() }  // after this returns WebRTC gets no more data
        }
        return true
    }

    /// One worker iteration: deliver a 10 ms chunk, or idle briefly while not recording.
    private func step() {
        condition.lock()
        guard let deliver else {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
            condition.unlock()
            nextTick = 0
            return
        }
        let count = min(pending.count, Self.chunk)
        for index in 0..<Self.chunk { buffer[index] = index < count ? pending[index] : 0 }
        pending.removeFirst(count)
        delivering = true
        condition.unlock()

        buffer.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            var actionFlags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = sampleTime
            timestamp.mFlags = .sampleTimeValid
            _ = deliver(&actionFlags, &timestamp, 1, UInt32(Self.chunk), &list, nil, nil)
        }
        locked { delivering = false; condition.broadcast() }

        sampleTime += Double(Self.chunk)
        let now = DispatchTime.now().uptimeNanoseconds
        if nextTick == 0 || now > nextTick + 100_000_000 { nextTick = now }  // (re)start, or resync after a stall
        nextTick += 10_000_000
        if nextTick > now { usleep(useconds_t((nextTick - now) / 1_000)) }
    }
}

enum AudioConversion {
    /// Downmixes float PCM (interleaved or planar channel pointers) to mono Int16.
    static func monoInt16(channels: [UnsafeBufferPointer<Float>], interleaved: Int = 1) -> [Int16] {
        guard let first = channels.first else { return [] }
        if interleaved > 1 {
            let frames = first.count / interleaved
            return (0..<frames).map { frame in
                var sum: Float = 0
                for channel in 0..<interleaved { sum += first[frame * interleaved + channel] }
                return clamp(sum / Float(interleaved))
            }
        }
        let frames = channels.map(\.count).min() ?? 0
        return (0..<frames).map { frame in clamp(channels.reduce(0) { $0 + $1[frame] } / Float(channels.count)) }
    }

    private static func clamp(_ value: Float) -> Int16 { Int16(max(-1, min(1, value)) * 32_767) }
}
