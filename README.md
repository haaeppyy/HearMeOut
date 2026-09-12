# EchoSign — VoIP-Only Backend (Hardened)

PSTN work (Twilio/Exotel/Agora hybrid) is shelved, not deleted — see the
project's chat history if that resumes. This zip strips it out entirely so
what's here is clean and focused: **app-to-app VoIP calling, done properly.**

## What changed from the last version — the real gaps that got closed

### 1. VoIP push was never actually implemented
`sendVoipPush` had been a `console.log` stub for the entire project, even
after everything else around it got built. Without it, a callee's phone
never rings regardless of what CallKit code exists client-side. Implemented
for real against Apple's HTTP/2 APNs Provider API — ES256 JWT auth,
`apns-topic` with the required `.voip` suffix, self-healing on stale tokens
(410/BadDeviceToken auto-clears the token so it isn't retried forever).

### 2. Nothing on the client was listening for pushes at all
`PushKitManager` was a fully untouched stub — `register()` did nothing,
`didReceiveIncomingPushWith` had no body, and it was never even
instantiated anywhere in the app. Even a working backend push had nowhere
to land. Implemented for real: registers for VoIP pushes, reports incoming
calls to CallKit, and closes the loop back to the backend on
answer/decline/hangup.

### 3. The callee had no way to actually join the call
The original `/calls` endpoint only ever issued an Agora token for the
*caller's* uid. There was no path for the callee's device to get its own
token once they answered — so even a perfectly-working push and perfectly-
working CallKit UI would have led to an answered call with nothing to join.
Added `/call-join`, which issues the callee their own scoped token for the
same channel, ownership-checked so only the actual callee can call it.

### 4. `PushKitManager` needed to be app-level, not per-screen
It has to be registered once at launch to catch calls regardless of what
screen is showing — if it were owned by a per-screen `CallViewModel`
(which is what the previous convenience-init pattern did), an incoming
call while the user wasn't on the dialer screen would never be caught.
Added `AppCallCoordinator`, owned once at the `EchoSignApp` level, holding
the shared `CallKitManager`/`AgoraService`/`PushKitManager`/
`CallSignalingClient`. `DialerView` was quietly constructing its own fully
isolated `CallViewModel` (separate `CallKitManager` instance) — fixed to
go through the shared coordinator instead, or none of the above would have
actually connected end to end.

### 5. A closure-clobbering bug that would have silently broken call cleanup
`CallKitManager.onCallEndedByCallKit` is a single closure property, and two
different pieces of code needed to react to it (`CallViewModel`, to reset
UI state; `PushKitManager`, to tell the backend a never-answered call
ended). Two independent assignments to the same property silently
overwrite each other — whichever ran last would have won, and the other
would have just stopped firing with no error. `AppCallCoordinator` is now
the single owner; both reactions happen from one place.

### 6. No real validation, no rate limiting, no call history
The original `/calls` endpoint would generate tokens and create a call row
for a `calleeId` that didn't exist, or for someone calling themselves,
with no rate limit on call attempts at all. Added: callee-exists check,
self-call block, DB-backed rate limiting (10 calls/minute — spam/harassment
guard, not just cost control), a proper `/call-history` endpoint, and
`missed` as a distinct call status from `failed` (an unanswered call is
normal usage, not an error — matters for any history/analytics view).

## What's genuinely solid now

Every piece above is built against Apple's or your own backend's actual,
documented/verified contracts — not a guess pending some third party's
provisioning, unlike most of the PSTN work. This is the first part of the
whole project that can honestly be called complete pending testing, rather
than complete pending someone else's approval.

## What still needs real device testing before you'd call this "done"

- The full push → CallKit → answer → `/call-join` → Agora-join chain has
  never run against a real device — it's built correctly against
  documented APIs, but "documented correctly" and "verified working" are
  different claims, and this project's history this session is a good
  reminder why that distinction matters.
- APNs environment (`APNS_ENVIRONMENT=sandbox` vs `production`) needs to
  match your build's actual provisioning profile, or pushes silently fail
  against the wrong environment.
- `Secrets.currentUserAuthToken()` is still a `fatalError` placeholder —
  wire it to your real Supabase Auth session before any of this can make
  a single real request.

## Setup needed (account/config, not code)

- Agora App ID + Certificate (Certificate stays server-side only, already
  handled correctly).
- Apple VoIP Services certificate/key (.p8), Key ID, Team ID, bundle ID —
  for real APNs push.
- Supabase project with the two migrations applied in order (001, 002).

## Not in scope here (unchanged)

PSTN (Twilio/Exotel/Agora bridge), transcript persistence, full Contact/
UserPreferences CRUD beyond what push-token registration needs, billing.
