# Discord TV Bridge

Watch a Discord call or screen share on Apple TV while you keep using Discord on your Mac. Two native apps send a selected window's video and application audio over WebRTC on your local network. Chat, joining rooms, and microphone input stay in the official Discord client.

**Early prototype:** the generated video/audio demo works in loopback tests and the tvOS simulator. Real Discord capture and physical Apple TV playback still require testing. No Discord login, private API, or account tokens are used.

## Try it

Requires an Apple Silicon Mac with macOS 14+, Xcode with the macOS/tvOS SDKs, Python 3, and an Apple TV with tvOS 17+ (or an Apple Silicon tvOS simulator).

1. Download the pinned WebRTC dependency: `Scripts/fetch-webrtc.sh`.
2. Open `DiscordTVBridge.xcodeproj`. Run the **MacSender** scheme on your Mac.
3. Choose **Try demo**, or allow Screen & System Audio Recording, select a Discord call window, and choose **Start sharing**. Allow Local Network access if prompted.
4. Run **TVReceiver** on Apple TV. Choose your Mac and enter the six-digit code. If the Mac isn't listed, choose **Enter address** and type the address displayed by the sender.
5. Press Back/Menu on the TV to disconnect, or **Stop** on the Mac to end sharing.

For a physical Apple TV, set your development team on the TVReceiver target and pair the device through Xcode's Devices and Simulators. The project has no signing team configured. The Mac app, installed app, and permission dialogs use the display name **Discord TV Sender**.

Keep the Discord window open and the Mac awake. For capture, audio includes the selected app and its helper processes, so other sounds from that app can also be sent. Your microphone is never captured by the bridge.

## Development

`Scripts/fetch-webrtc.sh` installs LiveKit's WebRTC XCFramework into the ignored `Vendor/` directory, verifies its archive checksum, and requires real macOS/tvOS slices. The Xcode project and Swift package share this copy. See [THIRD_PARTY.md](THIRD_PARTY.md) for provenance and licensing.

```sh
Scripts/fetch-webrtc.sh
python3 Scripts/generate-project.py
swift test
xcodebuild -project DiscordTVBridge.xcodeproj -scheme MacSender \
  -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- build
xcodebuild -project DiscordTVBridge.xcodeproj -scheme TVReceiver \
  -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

The Mac executable accepts `--demo` to send a moving test pattern and a 440 Hz tone. Demo mode logs its pairing code for testing; real window sharing does not. The 19 tests exercise cancellation, bounded reconnects, audio isolation, stable audio delivery, HTTP pairing and lockout, Bonjour discovery, audio conversion, and actual HEVC/H.264 WebRTC encode/decode and audio-packet delivery.

## Limits

- Same reachable local network only: no cloud service, STUN/TURN, or internet relay. Guest Wi-Fi/client isolation can block connections. Bonjour failure has a manual-address fallback.
- One TV at a time; connecting another TV replaces the current viewer. Audio is mono at 48 kHz. HEVC is preferred, with H.264 available.
- Media uses DTLS-SRTP encryption. Pairing and SDP signaling use **plain HTTP**, so use a trusted network: the six-digit code does not protect against an observer or active attacker on that network. Ten incorrect codes lock out new requests until sharing is restarted.
- TV speakers may feed back into your Discord microphone. Echo cancellation and screen-to-screen delay need testing on real devices. Do not interpret the loopback test's capture-to-decoded measurements as real TV latency.
- iPhone and Android sender apps are not implemented. Mobile screen and call-audio capture require separate platform validation.

## Install on a physical Apple TV

For the first test, install from Xcode rather than TestFlight:

1. Connect the Mac and Apple TV to the same network. On the TV, open **Settings → Remotes and Devices → Remote App and Devices**.
2. In Xcode, open **Device Hub** (Xcode → Open Developer Tool → Device Hub), choose **Pair Nearby Device**, and select Apple TV. Older Xcode versions use **Window → Devices and Simulators**. Enter the PIN shown on the TV.
3. Open this project, select the TVReceiver target, and set your **Signing & Capabilities → Team**, with automatic signing enabled.
4. Choose the **TVReceiver** scheme and your paired Apple TV as the run destination, then press **Run**.

TestFlight also supports tvOS, but this prototype has no uploaded TestFlight build. Distributing through TestFlight requires an Apple Developer Program account, an App Store Connect app record, and an uploaded distribution-signed archive. External testing requires Apple's beta review.

Apple references: [device pairing](https://developer.apple.com/documentation/xcode/pairing-your-devices-with-your-mac), [TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).
