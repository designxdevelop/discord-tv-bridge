# Project Environment

Inspection at session start found an empty workspace. Initial project setup is native Swift, with a macOS sender and tvOS receiver. React Native is not used.

```json
{
  "initial_project_type": "empty",
  "is_react_native": false,
  "project_type": "native_swift",
  "platforms": ["macOS", "tvOS"],
  "minimum_versions": {"macOS": "14.0", "tvOS": "17.0"},
  "xcode_version_observed": "27.2",
  "swift_version_observed": "6.4",
  "project_generator": "python3 Scripts/generate-project.py",
  "project": "DiscordTVBridge.xcodeproj",
  "schemes": ["MacSender", "TVReceiver"],
  "test_command": "swift test",
  "metro": null,
  "argent_available": true,
  "apple_tv_simulator_initially_available": false,
  "apple_tv_simulator_installed": "tvOS 27.2, Apple TV 4K (3rd generation) at 1080p",
  "transport_decision": "WebRTC",
  "public_repository": "https://github.com/designxdevelop/discord-tv-bridge"
}
```

Discord authentication, room selection, text chat, and microphone input remain in the official desktop client. The bridge captures a user-selected window and its application audio. Do not add private Discord API access or user-account tokens.
