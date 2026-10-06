import AVFoundation
import Network
import Observation
@preconcurrency import LiveKitWebRTC

@MainActor @Observable
final class ReceiverModel {
    typealias State = ReceiverSession.State

    struct Mac: Identifiable, Hashable {
        let name: String
        let baseURL: URL?  // from the Bonjour TXT record
        var id: String { name }
    }

    private(set) var macs: [Mac] = []
    var selectedMac: Mac?
    var manualAddress = ""
    var code = ""
    var preferHEVC = true
    var showStats = false
    private(set) var stats = ""

    let videoView: LKRTCMTLVideoView = {
        let view = LKRTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        return view
    }()

    @ObservationIgnored private let viewer = Viewer()
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var session: ReceiverSession!

    init() {
        let viewer = viewer
        session = ReceiverSession(connect: { [weak self] client in
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            try await viewer.connect(client, codec: self?.preferHEVC == false ? .h264 : nil)
        }, disconnect: { viewer.disconnect() })
        viewer.setRenderer(videoView)
        viewer.onState = { [weak self] peer, token in
            DispatchQueue.main.async {  // FIFO, so connected/disconnected arrive in order
                MainActor.assumeIsolated {
                    guard let self, viewer.isCurrent(token) else { return }  // events from replaced connections
                    self.session.peerChanged(peer)
                }
            }
        }
        Task { [weak self] in
            while let model = self {
                if model.showStats, let current = await viewer.stats() { model.stats = current.summary }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    var state: State { session.state }
    var isWatching: Bool { state != .setup }

    // MARK: Discovery

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Signaling.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Mac? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var url: URL?
                if case .bonjour(let txt) = result.metadata, let host = txt[Signaling.hostKey] {
                    url = Signaling.baseURL(fromAddress: "\(host):\(txt[Signaling.portKey] ?? String(Signaling.port))")
                }
                return Mac(name: name, baseURL: url)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in
                guard let self else { return }
                self.macs = found
                if self.selectedMac == nil || !found.contains(self.selectedMac!) { self.selectedMac = found.first }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    // MARK: Session

    func watch(manual: Bool) {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { session.reject("Enter the 6-digit code shown on your Mac."); return }
        let base = manual ? Signaling.baseURL(fromAddress: manualAddress) : selectedMac?.baseURL
        guard let base else {
            session.reject(WHEPClient.Failure.unreachable(manual ? "enter an address like 192.168.1.20:\(Signaling.port)"
                : "this Mac did not advertise an address; use Enter address").localizedDescription)
            return
        }
        session.start(WHEPClient(baseURL: base, code: digits))
    }

    func retry() { session.retry() }

    /// Back / Menu / leaving the app: abandon any attempt, tear down media and tell the Mac.
    func stop() {
        session.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
