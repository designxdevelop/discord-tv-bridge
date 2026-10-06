import SwiftUI
@preconcurrency import LiveKitWebRTC

struct ReceiverView: View {
    @State private var model = ReceiverModel()
    @State private var manual = false
    @FocusState private var focus: Field?
    @Environment(\.scenePhase) private var scenePhase

    private enum Field: Hashable { case code, address, watch, retry }
    private let accent = Color(red: 0.52, green: 0.61, blue: 1)

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.045, blue: 0.08).ignoresSafeArea()
            if model.isWatching {
                // Focusable so Menu/Back reaches onExitCommand while nothing else is on screen (otherwise tvOS exits the app).
                VideoSurface(view: model.videoView).ignoresSafeArea().focusable()
                overlay
            } else {
                setup
            }
        }
        .tint(accent)
        .onExitCommand { if model.isWatching { model.stop(); focus = .watch } }
        .onPlayPauseCommand { model.showStats.toggle() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stop() }
            if phase == .active { model.startBrowsing() }
        }
        .onChange(of: model.state) { _, state in if case .failed = state { focus = .retry } }
        .onAppear { model.startBrowsing() }
        .onDisappear { model.stop(); model.stopBrowsing() }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 26) {
            Label("DISCORD TV BRIDGE", systemImage: "tv").font(.headline).tracking(4).foregroundStyle(accent)
            Text("Your room.\nA bigger screen.").font(.system(size: 60, weight: .semibold))
            Text("Keep Discord on your Mac. Watch and listen here.").font(.title3).foregroundStyle(.secondary)
            if manual {
                TextField("Mac address, e.g. 192.168.1.20:\(String(Signaling.port))", text: $model.manualAddress)
                    .keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($focus, equals: .address)
            } else if model.macs.isEmpty {
                Label("Looking for Macs that are sharing…", systemImage: "magnifyingglass").foregroundStyle(.secondary)
            } else {
                Picker("Mac", selection: $model.selectedMac) {
                    ForEach(model.macs) { Text($0.name).tag(Optional($0)) }
                }
            }
            HStack(spacing: 24) {
                TextField("6-digit code from your Mac", text: $model.code)
                    .keyboardType(.numberPad).frame(maxWidth: 520)
                    .focused($focus, equals: .code)
                    .onSubmit { model.watch(manual: manual) }
                Button("Watch on TV", systemImage: "play.fill") { model.watch(manual: manual) }
                    .buttonStyle(.borderedProminent)
                    .focused($focus, equals: .watch)
                    .disabled(model.code.filter(\.isNumber).count != 6 || (!manual && model.selectedMac == nil))
            }
            HStack(spacing: 24) {
                Button(manual ? "Find Macs automatically" : "Enter address") { manual.toggle() }
                Toggle("Prefer HEVC", isOn: $model.preferHEVC).frame(maxWidth: 420)
            }
            Text("Same network as your Mac. Your microphone and call controls stay on the Mac.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 1200, alignment: .leading)
        .padding(70)
        .onAppear { focus = .code }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.state {
        case .connecting, .reconnecting:
            VStack(spacing: 20) {
                ProgressView().scaleEffect(1.5)
                if case .reconnecting(let attempt) = model.state {
                    Text(attempt == 0 ? "Connection interrupted, recovering…" : "Reconnecting (attempt \(attempt))…").font(.title2)
                } else {
                    Text("Connecting to your Mac…").font(.title2)
                }
                Button("Cancel") { model.stop() }
            }
            .padding(48).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        case .failed(let message):
            VStack(spacing: 24) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(accent)
                Text("Stream unavailable").font(.title)
                Text(message).font(.callout).multilineTextAlignment(.center)
                HStack(spacing: 28) {
                    Button("Retry", systemImage: "arrow.clockwise") { model.retry() }.focused($focus, equals: .retry)
                    Button("Back") { model.stop() }
                }
            }
            .frame(maxWidth: 850).padding(48)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        case .playing:
            if model.showStats {
                VStack {
                    Spacer()
                    Text(model.stats).font(.caption.monospaced()).padding(12)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(40)
            }
        case .setup:
            EmptyView()
        }
    }
}

/// Metal renderer from WebRTC; frames arrive from the decoder thread.
private struct VideoSurface: UIViewRepresentable {
    let view: LKRTCMTLVideoView
    func makeUIView(context: Context) -> LKRTCMTLVideoView { view }
    func updateUIView(_ uiView: LKRTCMTLVideoView, context: Context) {}
}
