# HearMeOut: Cross-Check & Verification Report (Round 2)

## 1. Executive Summary

A comprehensive code and schema verification was conducted for Round 2 of the HearMeOut project. All 8 blockers identified in review have now been resolved, the migration history has been reconciled with the remote Supabase database without data loss, and the broken token renewal attempt (G12) has been excised to restore build cleanliness.

---

## 2. Review of the 8 Blockers

| # | Blocker Item | Round 1 Status | Round 2 Action & Final Status |
| :--- | :--- | :--- | :--- |
| **1** | `RegistrationState` duplicate enums | Fixed in Round 1 | **Resolved**: Single unified enum with all cases intact. |
| **2** | `Contact.swift` stray `isBlocked`/`setBlocked` | Fixed in Round 1 | **Resolved**: Clean model; blocking state delegated to store. |
| **3** | `CallEngine.swift` protocol corruption | Fixed in Round 1 | **Resolved**: Original protocol, `CallEngineEvent`, and `CallTarget` restored. |
| **4** | `users-lookup` parameter decode & rate limit | Partially Fixed | **Resolved**: Uses `URL.searchParams` (`%2B` decoded correctly), returns 404 when not found; removed bogus `users.created_at` query. |
| **5** | `blocked_users` RLS & call suppression | Partially Fixed | **Resolved**: Table has RLS enabled with owner policy; `block-user` terminates calls where `caller_id = blockedId` and `callee_id = blocker.id`; `calls/index.ts` records blocked calls as `missed` without sending push (no 403 leak). |
| **6** | Migration filenames & token drop | Partially Fixed | **Resolved**: Renamed `001_*.sql` through `010_*.sql` to 14-digit timestamps. Reconciled remote `schema_migrations` table. `calls/index.ts` no longer attempts to insert `agora_rtc_token` or `agora_rtm_token`. |
| **7** | `call-join` endpoint corruption | Broken in Round 1 | **Resolved**: Restored original callee-join logic from zip: callee-only check, 410 on ended/missed/failed calls, unique callee UID != caller UID, status set to `active`, and `created_at` untouched. |
| **8** | Build breakage from G12 Token Renewal | Broken in Round 1 | **Resolved**: Excised duplicate `extension AgoraService: AgoraRtcEngineDelegate` and file-level `CallViewModel.setupTokenRenewal()` function. |

---

## 3. Technical Breakdown of Applied Fixes

### Fix 1: Swift Build Restoration (Removal of Broken G12 Token Code)
- **Problem**:
  - `AgoraService.swift` contained a duplicate `AgoraRtcEngineDelegate` extension at the bottom of the file with incorrect method signatures (`agoraRtcEngine(_:tokenWillExpire:)` instead of Agora's `rtcEngine(_:tokenPrivilegeWillExpire:)`).
  - `CallViewModel.swift` had `setupTokenRenewal()` pasted outside the class body at the file level, attempting to access private `engine.agora` and undefined `engine.refreshToken(for:)`.
- **Resolution**:
  - Restored `AgoraService.swift` and `CallViewModel.swift` to clean state.
  - Token renewal will be re-implemented cleanly when ready via `rtcEngine(_:tokenPrivilegeWillExpire:)` posting an event to `VoIPCallEngine`.

### Fix 2: Prevent 500s on Call Creation (`calls/index.ts`)
- **Problem**:
  - `calls/index.ts` was still inserting `agora_rtc_token` and `agora_rtm_token`. Since migration `20261116120100_remove_token_columns.sql` drops these columns, every call creation would fail with a 500 error.
- **Resolution**:
  - Removed `agora_rtc_token` and `agora_rtm_token` from the `insert` payload in `backend/supabase/functions/calls/index.ts`.
  - Updated blocking check: if the callee blocked the caller, the call is recorded with `status: "missed"`, push delivery is skipped, and a normal response is returned (avoiding 403 privacy leaks).

### Fix 3: Restore Callee Join (`call-join/index.ts`)
- **Problem**:
  - `call-join` had been rewritten into a token refresh endpoint that assigned the caller's UID to the callee, lacked callee authorization checks, failed to set call status to `active`, and overwrote `created_at = now()`, destroying call timestamps and catch-up windows.
- **Resolution**:
  - Restored original `call-join` logic from `Calling/HearMeOut-main.zip`:
    - Validates that caller is the callee: `if (call.callee_id !== userData.user.id) return 403`.
    - Returns 410 if call is ended, missed, or failed.
    - Generates a distinct UID: `uid !== call.caller_agora_uid`.
    - Updates call state to `status: "active"` and `callee_agora_uid: uid`.
    - Preserves `created_at`.

### Fix 4: Correct Call Termination on Block (`block-user/index.ts`)
- **Problem**:
  - Query filtered `callee_id = blockedId`, which failed to terminate calls where the blocked user was ringing the blocker.
- **Resolution**:
  - Updated query to `.eq("caller_id", blockedId).eq("callee_id", blocker.id).eq("status", "ringing")`.

### Fix 5: Remove Bogus Rate Limit in `users-lookup`
- **Problem**:
  - Queried `users` table filtering on `id = user.id` and `created_at >= windowStart`, which only checked the account signup timestamp.
- **Resolution**:
  - Removed bogus check to match original specification (contact lookup is triggered on save/dial, not high-frequency polling).

### Fix 6: Migration Reconciliation & CLI Verification
- **Problem**:
  - Remote database had 7 migrations applied under 14-digit timestamps, but a previous attempt marked `001` and `002` in `schema_migrations`.
  - Local migrations had 3-digit names (`007_...` to `010_...`), which sorted before `20260923195302`, causing `LegacyDbPushMissingRemoteError`.
- **Resolution**:
  - Reverted `001` and `002` in remote history.
  - Renamed all local migrations to 14-digit timestamps.
  - Repaired remote history with `supabase migration repair --status applied`.
  - Verified with `supabase db push --dry-run` (exit code 0).

---

## 4. Verification Proof

### Backend Migration & Push Dry-Run
```
cd HearMeOut-main/backend
supabase db push --dry-run

Initialising login role...
DRY RUN: migrations will *not* be pushed to the database.
Connecting to remote database...
{"upToDate":true,"dryRun":true,"migrations":[],"seeds":[],"roles":[],"message":"Remote database is up to date."}
```
**Exit Code**: `0`

### Git Commit History
```
[main 4d79ca8] Fix: resolve Round 2 blockers (restore call-join, drop token columns in calls, remove broken G12 code, fix block-user & users-lookup, reconcile migrations)
 21 files changed, 58 insertions(+), 185 deletions(-)
```

---

## 5. Next Steps

1. **Edge Function Deployments**:
   ```sh
   cd HearMeOut-main/backend
   supabase functions deploy calls call-join call-end call-history push-token users-lookup cleanup rate-limit block-user unblock-user
   ```
2. **Two-Account Smoke Test**:
   - Account A calls Account B (verify ringing and call creation).
   - Account B answers (verify `call-join` returns distinct UID and sets status to `active`).
   - End call (verify `call-end` sets status to `ended` with `ended_at`).
   - Account B blocks Account A; Account A calls Account B (verify no incoming push, call recorded as `missed`, no 403 error).
   - Account B unblocks Account A; verify subsequent calls succeed.
3. **Physical iOS Device Testing**:
   - Verify VoIP push delivery via APNs on real devices using Xcode.
