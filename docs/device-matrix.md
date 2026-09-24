# Device Matrix (Layer 4) — physical-iPhone checklist

One iPhone is enough for most of this (second party played by
`scripts/virtual-callee.sh` from the app repo, or a second account in the
harness). Full-duplex items need a second device or TestFlight loaner.

## Setup (once per device)

- [ ] App installed from Xcode (Debug, dev team set), mic permission granted.
- [ ] `Config.xcconfig` points at the target project (staging first).
- [ ] Signed up in-app (email, confirmation OFF on the target project).
- [ ] Contact `+15550001111` saved (resolves to the harness user B).

## Speech plane (Profile → Engine Test, no call)

- [ ] STT: Start Listening → speak continuously past 60 s → transcript keeps
      flowing across the seamless restart with no dropped boundary words.
- [ ] TTS: typed text → Speak → audible, stats line advances
      (`cb/pcm/src/out/played`), route shows Speaker.
- [ ] Sanity control audible (isolates session/route vs pipeline faults).
- [ ] Deny mic/speech permission paths show the Settings guidance, no crash.

## Calls (single device + harness)

- [ ] Outgoing audio: dial linked contact → ringing → answer via harness
      `join` → two-way audio → end → history row with duration.
- [ ] Type & Speak: typed reply is HEARD on the other end (harness can't hear
      — verify on second device when available; otherwise assert
      `pushExternalAudioFrame` attempts advance with zero failures).
- [ ] Live captions: remote speech appears under LIVE CAPTIONS within ~2 s.
- [ ] Mute during TTS: stays muted after synthesis ends (duck coordinator).
- [ ] kills: airplane-mode mid-call → error surfaces, call ends cleanly.

## Incoming (needs APNs secrets deployed)

- [ ] Harness `call <A-id>` → device rings with native CallKit UI < 3 s.
- [ ] Decline → caller sees `missed`; answer → `active` → audio both ways.
- [ ] Kill app, repeat → cold-start ring via PushKit.
- [ ] Uninstall/reinstall → dead token self-heals (410 → row deleted,
      next call reports `pushDelivered: false` instead of hanging).

## Upgrade note

Simulator proves UI + backend wiring only. VoIP audio, recognition accuracy,
and pushes are device-only — never sign off a release on simulator runs.
