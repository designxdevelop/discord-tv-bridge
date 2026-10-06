# Third-party dependencies

## LiveKitWebRTC.xcframework 150.7871.03 (not committed)

- Source: https://github.com/livekit/webrtc-xcframework, release `150.7871.03`
  (`LiveKitWebRTC.xcframework.zip`, SHA-256 `5727a03c32ed902da570b699e3983e3fb4bfe853ab4da045af70912a7db44557`).
- What it is: Google libwebrtc (branch M150) built by LiveKit with Objective-C API, class prefix `LK`
  (`LKRTCPeerConnectionFactory`, …). Slices used: `macos-arm64_x86_64` (min macOS 10.15), `tvos-arm64`
  and `tvos-arm64-simulator` (both `LC_BUILD_VERSION` platform tvOS / tvOS-simulator, min 17.0).
- License: BSD-3-Clause (WebRTC project), shipped as `LICENSE` inside the XCFramework; also covers bundled
  third-party code listed by libwebrtc. Include it in app acknowledgements before distribution.
- Install: `Scripts/fetch-webrtc.sh` downloads it to `Vendor/` (git-ignored) and verifies the checksum.
  Both `Package.swift` (binary target by path) and the Xcode project reference that one copy.
- Codecs used: VideoToolbox H.265 (HEVC) encoder/decoder, VideoToolbox H.264 encoder/decoder, Opus.
