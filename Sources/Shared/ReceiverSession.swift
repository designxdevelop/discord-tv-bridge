import Foundation
import Observation

/// The TV's connection lifecycle, separate from WebRTC so it can be tested. Every attempt owns a generation:
/// stop, a new attempt or a retry bumps it, and stale attempts can neither change `state` nor tear anything down.
/// One retry budget spans signaling and media failures and refills only when media actually connects.
@MainActor @Observable
final class ReceiverSession {
    enum State: Equatable {
        case setup
        case connecting
        case playing
        case reconnecting(attempt: Int)
        case failed(String)
    }

    typealias Connect = @MainActor (WHEPClient) async throws -> Void
    static let maxReconnects = 3
    static let lostMessage = "Lost the connection to your Mac. Check that both devices are on the same network."
    static let stoppedMessage = "Sharing stopped on the Mac. Start sharing again, choose Back, and enter the new code."

    private(set) var state: State = .setup
    @ObservationIgnored private let connectPeer: Connect
    @ObservationIgnored private let disconnectPeer: @MainActor () -> Void
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let recoveryWait: Duration
    @ObservationIgnored private var client: WHEPClient?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `connect` must finish signaling and throw on failure; `disconnect` must free media and the Mac's session.
    init(connect: @escaping Connect, disconnect: @escaping @MainActor () -> Void,
         retryDelay: Duration = .seconds(2), recoveryWait: Duration = .seconds(10)) {
        connectPeer = connect
        disconnectPeer = disconnect
        self.retryDelay = retryDelay
        self.recoveryWait = recoveryWait
    }

    var canRetry: Bool { client != nil }

    func start(_ client: WHEPClient) {
        self.client = client
        failures = 0
        state = .connecting
        attempt(after: .zero)
    }

    func retry() {
        guard let client else { state = .setup; return }
        start(client)
    }

    /// Shows a problem found before connecting (incomplete code, bad address).
    func reject(_ message: String) {
        stop()
        state = .failed(message)
    }

    /// Back / Cancel: abandons any attempt in flight (it cleans up its own session) and frees the current one.
    func stop() {
        finish(.setup)
        client = nil
    }

    /// Feed media state from the *current* connection only.
    func peerChanged(_ peer: PeerState) {
        switch (peer, state) {
        case (_, .setup), (_, .failed): return
        case (.connected, _):
            failures = 0
            state = .playing
        case (.disconnected, .playing):
            // ICE often recovers by itself after a Wi-Fi blip, but a crashed/asleep Mac can leave it hanging.
            state = .reconnecting(attempt: 0)
            let mine = generation
            let wait = recoveryWait
            Task {  // not `task`: cancelling an attempt that is still finishing would tear down a working connection
                try? await Task.sleep(for: wait)
                guard mine == generation, state == .reconnecting(attempt: 0) else { return }
                failed(MediaError.connectionLost)
            }
        case (.failed, _):
            failed(MediaError.connectionLost)
        case (.closed, _):
            finish(.failed(Self.stoppedMessage))
        default:
            break
        }
    }

    private func advance() -> Int {
        generation += 1
        task?.cancel()
        task = nil
        return generation
    }

    private func finish(_ final: State) {
        _ = advance()
        disconnectPeer()
        state = final
    }

    private func attempt(after delay: Duration) {
        let mine = advance()
        task = Task {
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                guard mine == generation, let client else { return }
                try await connectPeer(client)
            } catch {
                guard mine == generation, !(error is CancellationError) else { return }  // stale: not ours to report
                failed(error)
            }
        }
    }

    private func failed(_ error: Error) {
        let fatal = (error as? WHEPClient.Failure).map { $0 == .wrongCode || $0 == .lockedOut } ?? false
        // A first attempt that can't even signal shows the real reason (bad address, sharing off) at once.
        if fatal || (state == .connecting && !(error is MediaError)) {
            finish(.failed(error.localizedDescription))
            return
        }
        failures += 1
        guard failures <= Self.maxReconnects else { finish(.failed(Self.lostMessage)); return }
        disconnectPeer()
        state = .reconnecting(attempt: failures)
        attempt(after: retryDelay)
    }
}

/// Which ScreenCaptureKit applications count as "the selected window's app" for audio: the owner itself and
/// helper apps bundled inside it (Discord plays call audio from "Discord Helper" processes). Same-prefix
/// siblings such as com.vendor.AppBeta, or helpers installed elsewhere, are excluded.
enum AudioScope {
    static func includes(bundleID: String, bundlePath: String?, ownerID: String, ownerPath: String?) -> Bool {
        guard !ownerID.isEmpty else { return false }
        if bundleID == ownerID { return true }
        guard bundleID.hasPrefix(ownerID + "."), let bundlePath, let ownerPath else { return false }
        let owner = URL(fileURLWithPath: ownerPath).standardizedFileURL.path
        let helper = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        return helper.hasPrefix(owner.hasSuffix("/") ? owner : owner + "/")
    }
}
