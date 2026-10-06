# Validation record

WebRTC prototype checked locally on 2026-10-06 with Xcode 27.2 / Swift 6.4 and the tvOS 27.2 Apple TV 4K simulator.

## Observed

- `swift test`: 19 tests passed, including two live WebRTC media-loopback cases.
- HEVC loopback: median capture-to-decoded delay 21.1 ms; 95th percentile 23.4 ms.
- H.264 loopback: median 17.6 ms; 95th percentile 19.4 ms.
- Both cases decoded video with VideoToolbox and received audio packets.
- The native Apple TV receiver displayed the moving demo pattern after Bonjour discovery and pairing-code entry.
- Opus's implementation pass also exercised manual address entry, wrong-code rejection, sender shutdown, and retry behavior. Sol's first review found five cancellation, audio-isolation, and disconnect/retry defects; the second review found two narrower ownership races. Opus fixed all seven. Sol's final high-effort pass reported no remaining must-fix findings. The last two fixes passed all 19 tests and both app builds; their narrow timing windows were checked by code review rather than new dedicated tests.
- The fix pass verified Back during playback returns to setup, reconnect plays video again, and sender termination eventually exhausts the retry budget.
- New regression tests cover abandoned handshakes, superseded connections, audio helper isolation, bounded media-failure retries, a stable audio worker thread, and audio resuming after reconnect.

These loopback measurements exclude actual Wi-Fi transit, audio hardware, TV decoding hardware, and display time. They do not measure screen-to-screen delay or establish call quality.

## Still requires hardware/user validation

- Grant macOS Screen & System Audio Recording and Local Network permissions.
- Select a real Discord window; verify video and application/helper-process audio while chatting through Discord's microphone.
- Run TVReceiver on a signed physical Apple TV; listen to stream and call audio.
- Check echo, video/audio synchronization, and perceived conversation delay on the actual network.

No private Discord window was captured for these checks. Demo mode uses synthetic video and a tone.
