#!/bin/sh
# Downloads the pinned, checksum-verified LiveKit WebRTC XCFramework (macOS + tvOS slices) into Vendor/.
# Source: https://github.com/livekit/webrtc-xcframework (BSD-3-Clause, built from libwebrtc M150).
set -eu
VERSION=150.7871.03
SHA256=5727a03c32ed902da570b699e3983e3fb4bfe853ab4da045af70912a7db44557
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/Vendor/LiveKitWebRTC.xcframework"
STAMP="$ROOT/Vendor/.webrtc-$VERSION"
[ -f "$STAMP" ] && [ -d "$DEST" ] && { echo "LiveKitWebRTC $VERSION already present"; exit 0; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fL --retry 3 -o "$TMP/webrtc.zip" "https://github.com/livekit/webrtc-xcframework/releases/download/$VERSION/LiveKitWebRTC.xcframework.zip"
echo "$SHA256  $TMP/webrtc.zip" | shasum -a 256 -c -
mkdir -p "$TMP/x"
unzip -q "$TMP/webrtc.zip" -d "$TMP/x"
for slice in macos-arm64_x86_64 tvos-arm64 tvos-arm64-simulator; do
  [ -d "$TMP/x/LiveKitWebRTC.xcframework/$slice" ] || { echo "missing $slice slice" >&2; exit 1; }
done
rm -rf "$DEST" "$ROOT"/Vendor/.webrtc-*
mkdir -p "$ROOT/Vendor"
mv "$TMP/x/LiveKitWebRTC.xcframework" "$DEST"
touch "$STAMP"
echo "Installed LiveKitWebRTC $VERSION"
