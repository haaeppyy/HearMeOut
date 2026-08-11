# EchoSign — VoIP Call Prototype

A minimal iOS prototype for app-to-app VoIP calls with two custom features layered on top of the call:

- **Live captions** of the remote speaker, shown in the call UI.
- **Type & Speak** — typed text is synthesized and injected into the outgoing call audio so the other party hears it.

Built with SwiftUI + Agora RTC (4.x), CallKit for the native call UI, and `SFSpeechRecognizer` for captioning.

## What it does

- Both phones enter the same channel ID and press Call. No accounts, no backend.
- CallKit native in-call UI for the outgoing call lifecycle.
- Remote-party speech is transcribed on-device (16 kHz mono PCM piped from Agora's playback frames).
- Type & Speak renders text offline via `AVSpeechSynthesizer.write` and pushes PCM into the outgoing stream via Agora's custom audio track (mic is muted while it plays).
- Incoming calls / PushKit are stubbed (`PushKitManager`) with `// TODO: incoming call` markers.

## Requirements

- Xcode 15+, iOS 17+, two physical iPhones.
- An Agora project: paste `AGORA_APP_ID` and a `AGORA_TEMP_TOKEN` into `EchoSign/Secrets.swift` (single place).

## Build

```sh
brew install xcodegen
xcodegen generate
open EchoSign.xcodeproj
```

Then in Xcode: set your development team (Signing & Capabilities), and verify the capabilities below are present (XcodeGen generates them, but re-check after first open).

## Project layout

```
project.yml                     XcodeGen project spec (Agora SPM, entitlements, plist keys)
EchoSign/
  App/EchoSignApp.swift         @main; audio session baseline; PushKit stub registration
  Features/Dialer/DialerView.swift
  Features/Call/CallView.swift
  Features/Call/CallViewModel.swift
  Services/VoIP/AgoraService.swift     Agora engine wrapper, captions pipe, TTS custom track
  Services/VoIP/CallKitManager.swift   CXProvider/CXCallController outgoing lifecycle
  Services/VoIP/PushKitManager.swift   Stub — incoming calls, see TODOs
  Services/Speech/CaptionService.swift SFSpeechRecognizer, .local/.remote sources
  Services/Speech/TTSService.swift     AVSpeechSynthesizer.write -> Agora custom track
  Models/CallState.swift
  Secrets.swift                 Credential placeholders
```

## Known limitations

- Outgoing calls only; incoming calls are stubbed (no PushKit/backend wiring).
- No PSTN, no accounts/auth, no persistent backend. Temp tokens expire (~24h) — regenerate from Agora Console when testing breaks after a day.
- The simulator is unreliable for VoIP audio — test on two physical iPhones.
- On-device speech recognition has a ~60 s session limit; `CaptionService` restarts the task seamlessly, but very long monologues may drop a word at each boundary.
