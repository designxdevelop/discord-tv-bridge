import SwiftUI
import Observation
@preconcurrency import ScreenCaptureKit
import AppKit

/// One model per process: SwiftUI may construct the App struct more than once, and a second model
/// would orphan the running server. `--demo` starts without waiting for a window (works headless).
@MainActor private let senderModel: SenderModel = {
    let model = SenderModel()
    if ProcessInfo.processInfo.arguments.contains("--demo") { Task { await model.start(demo: true) } }
    return model
}()

@main
struct DiscordTVSenderApp: App {
    private var model: SenderModel { senderModel }

    init() { _ = senderModel }  // create (and start a demo) even if no window is ever shown

    var body: some Scene {
        WindowGroup("Discord TV Sender") {
            SenderView(model: model)
                .frame(minWidth: 600, minHeight: 480)
                .task { if model.phase == .idle { await model.refreshWindows() } }
        }
    }
}

@MainActor @Observable
final class SenderModel {
    enum Phase: Equatable {
        case idle
        case starting
        case waitingForTV
        case tv(peer: String, state: PeerState)
    }

    var windows: [SCWindow] = []
    var selectedWindowID: CGWindowID?
    var phase: Phase = .idle
    var isDemo = false
    var status = "Choose a Discord window to share its picture and application audio."
    var errorMessage: String?
    private(set) var code = ""
    private(set) var address = ""
    @ObservationIgnored private var content: SCShareableContent?
    @ObservationIgnored private var publisher: Publisher?
    @ObservationIgnored private var server: SignalingServer?
    @ObservationIgnored private var capture: WindowCapture?
    @ObservationIgnored private var demo: DemoFeeder?
    @ObservationIgnored private var generation = 0  // bumps on start/stop; late callbacks from older sessions are ignored
    @ObservationIgnored private var stopping: Task<Void, Never>?  // older captures still shutting down; start waits for it

    var isSharing: Bool { phase != .idle && phase != .starting }

    init() {
        // Quitting closes the TV's control channel so it shows "sharing stopped" at once instead of timing out.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publisher?.stop() }
        }
    }

    func refreshWindows() async {
        guard phase == .idle else { return }
        errorMessage = nil
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            self.content = content
            windows = content.windows.filter { window in
                window.frame.width > 80 && window.frame.height > 80 && !(window.title ?? "").isEmpty &&
                    window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
            }.sorted {
                let first = $0.owningApplication?.applicationName.localizedCaseInsensitiveContains("discord") == true
                let second = $1.owningApplication?.applicationName.localizedCaseInsensitiveContains("discord") == true
                return first != second ? first : windowTitle($0) < windowTitle($1)
            }
            if !windows.contains(where: { $0.windowID == selectedWindowID }) { selectedWindowID = windows.first?.windowID }
            status = windows.isEmpty ? "No shareable windows found. Open Discord, then refresh."
                : "Select the call or stream window, then start sharing."
        } catch {
            errorMessage = "Cannot list windows: \(error.localizedDescription)\nAllow Discord TV Sender in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app."
        }
    }

    func windowTitle(_ window: SCWindow) -> String {
        "\(window.owningApplication?.applicationName ?? "App") — \(window.title ?? "Window")"
    }

    func start(demo: Bool) async {
        guard phase == .idle else { return }
        let window = windows.first { $0.windowID == selectedWindowID }
        guard demo || (window != nil && content != nil) else { errorMessage = "Refresh windows and select one before sharing."; return }
        phase = .starting
        errorMessage = nil
        isDemo = demo
        status = "Starting…"
        generation += 1
        let mine = generation
        await stopping?.value  // never run two captures of one window at once
        guard generation == mine else { return }  // stopped while waiting
        /// Runs `body` on the main actor, in order, only while this sharing session is still current.
        let current: @Sendable (@escaping @MainActor (SenderModel) -> Void) -> Void = { [weak self] body in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if let self, self.generation == mine { body(self) } }
            }
        }
        let publisher = Publisher()
        let code = Signaling.randomCode()
        publisher.onViewerState = { peer, state in current { $0.viewerChanged(peer: peer, state: state) } }
        let routes = WHEPEndpoint(code: code, createSession: { try await publisher.answer(offer: $0, peer: $1) },
                                  deleteSession: { publisher.endViewer(id: $0) },
                                  onLockout: {
                                      current { $0.errorMessage = "Too many wrong pairing codes. Stop and start sharing to get a new code." }
                                  })
        let server = SignalingServer { await routes.respond(to: $0, peer: $1) }
        self.publisher = publisher
        self.server = server
        do {
            try await server.start(serviceName: Host.current().localizedName ?? "Mac")
            guard generation == mine else { server.stop(); return }  // stopped while starting; stop() cleaned the rest
            if demo {
                self.demo = DemoFeeder(publisher: publisher)
            } else if let window, let content {
                let output = CaptureOutput(publisher: publisher) { message in
                    current { model in Task { await model.stop(error: "Capture stopped: \(message)", generation: mine) } }
                }
                let capture = WindowCapture()
                self.capture = capture
                try await capture.start(window: window, content: content, output: output)
                guard generation == mine else { await capture.stop(); return }  // may have started after stop() ran
            }
            self.code = code
            address = "\(LocalNetwork.ipv4Address() ?? "this Mac's IP"):\(Signaling.port)"
            phase = .waitingForTV
            status = demo ? "Demo is live: moving picture and a 440 Hz tone." : "Sharing \(window.map(windowTitle) ?? "window")."
            if demo { FileHandle.standardError.write(Data("Discord TV Bridge demo: pairing code \(code), address \(address)\n".utf8)) }  // test pattern only; never for real windows
        } catch {
            guard generation == mine else { return }
            let message = (error as NSError).domain == "NWErrorDomain" && (error as NSError).code == Int(EADDRINUSE)
                ? "Port \(Signaling.port) is in use. Quit other Discord TV Sender copies and try again."
                : error.localizedDescription
            await stop(error: message)
        }
    }

    /// Detaches and stops this session's resources synchronously, so nothing after the one await can touch a newer
    /// session. `generation` limits the stop to that session (for callbacks that may run late).
    func stop(error: String? = nil, generation expected: Int? = nil) async {
        guard phase != .idle, expected == nil || expected == generation else { return }
        generation += 1
        let (demo, capture, publisher, server, previous) = (demo, capture, publisher, server, stopping)
        (self.demo, self.capture, self.publisher, self.server) = (nil, nil, nil, nil)
        demo?.stop()
        publisher?.stop()  // closes the TV's control channel so it shows "sharing stopped" immediately
        server?.stop()
        code = ""
        phase = .idle
        errorMessage = error
        status = error == nil ? "Sharing stopped." : "Sharing stopped because of an error."
        let task = Task { await previous?.value; await capture?.stop() }
        stopping = task
        await task.value
    }

    private func viewerChanged(peer: String, state: PeerState) {
        guard isSharing else { return }
        switch state {
        case .failed, .closed: phase = .waitingForTV
        default: phase = .tv(peer: peer, state: state)
        }
    }
}

private struct SenderView: View {
    @Bindable var model: SenderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Discord TV Bridge", systemImage: "tv.and.mediabox").font(.largeTitle.bold())
            Text("Discord on your Mac. Picture and sound on your TV.").foregroundStyle(.secondary)
            HStack {
                Picker("Window", selection: $model.selectedWindowID) {
                    Text("Select a window").tag(nil as CGWindowID?)
                    ForEach(model.windows, id: \.windowID) { Text(model.windowTitle($0)).tag(Optional($0.windowID)) }
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshWindows() } }
            }
            .disabled(model.phase != .idle)
            HStack {
                Button("Start sharing", systemImage: "play.fill") { Task { await model.start(demo: false) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase != .idle || model.selectedWindowID == nil)
                Button("Try demo", systemImage: "testtube.2") { Task { await model.start(demo: true) } }
                    .disabled(model.phase != .idle)
                Button("Stop", systemImage: "stop.fill") { Task { await model.stop() } }
                    .disabled(!model.isSharing)
                if model.phase == .starting { ProgressView().controlSize(.small) }
            }
            Text(model.status)
            if model.isSharing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On Apple TV, open Discord TV Receiver, pick this Mac and enter:").font(.headline)
                    Text(model.code.count == 6 ? "\(model.code.prefix(3)) \(model.code.suffix(3))" : model.code)
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Not listed on the TV? Choose “Enter address” and type \(model.address)")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Label(viewerText, systemImage: viewerIcon).padding(.top, 4)
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer(minLength: 0)
            Text("Same local network required. Video is HEVC or H.264, encrypted end to end with WebRTC (DTLS-SRTP). Your microphone, chat and call controls stay in Discord; this app never captures your microphone.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private var viewerText: String {
        switch model.phase {
        case .tv(let peer, .connected): "Apple TV \(peer) is watching."
        case .tv(let peer, .disconnected): "Apple TV \(peer) lost connection; waiting for it to recover…"
        case .tv(let peer, _): "Apple TV \(peer) is connecting…"
        default: "Waiting for Apple TV…"
        }
    }

    private var viewerIcon: String {
        if case .tv(_, .connected) = model.phase { return "checkmark.circle.fill" }
        return "hourglass"
    }
}
