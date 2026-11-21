# HearMeOut VoIP

HearMeOut is an iOS SwiftUI app for direct app-to-app audio calls. Agora carries audio; Supabase authenticates users and provides signaling; PushKit and CallKit present incoming calls.

Simulator receives calls only while the app is in the foreground.

## What is in this repository

- The iOS app uses Supabase email/password authentication. The dialer is not available until a session is restored or the user signs in.
- Each signed-in user saves one phone number. A 10-digit number is normalized
  with the `+91` default; full `+` international numbers are kept as entered.
  Calls can be placed by phone number or user UUID. The server creates a new,
  private Agora channel for each call; channel IDs are never shared in the UI.
- VoIP token registration is retried after sign-in, including when PushKit supplied the token before authentication completed.
- The app subscribes to Supabase Realtime for foreground incoming calls and
  performs a 45-second ringing-call catch-up query after subscribing and on
  return to foreground. This is the incoming-call path used by a simulator.
- Push delivery code is bundled at `backend/supabase/functions/_shared/push.ts`, so Edge Functions do not import source files outside the Supabase functions directory.

## Setup

1. Create a Supabase project. In Authentication, enable email/password and, for the quickest two-phone test, either disable email confirmation or confirm each test account before signing in.
2. Link the local backend to that project, review migration history first, and apply the migrations in numeric order. Do not run `006_cron_cleanup.sql` unchanged: replace both placeholders with your project Functions base URL and a newly generated `CRON_SECRET` before applying it.

   ```sh
   cd backend
   supabase link --project-ref YOUR_PROJECT_REF
   supabase migration list
   supabase db push
   ```

   `002_users.sql` creates `public.users` before `003_voip_hardening.sql` alters it. `007_users_display_name_fallback.sql` updates the auth trigger to derive a display name from the email prefix when metadata has none; `008_users_service_role_writes.sql` removes direct profile writes by authenticated clients.
3. Set Edge Function secrets. Never place these values in the app or commit them:

   ```sh
   supabase secrets set \
     AGORA_APP_ID=... \
     AGORA_APP_CERTIFICATE=... \
     APNS_KEY_ID=... \
     APNS_TEAM_ID=... \
     APNS_PRIVATE_KEY='-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----' \
     APNS_BUNDLE_ID=dev.echo.HearMeOut \
     APNS_ENVIRONMENT=sandbox \
     CRON_SECRET='a-long-random-value'
   ```

   `APNS_BUNDLE_ID` has no `.voip` suffix; the function appends it. Use `sandbox` for Xcode development provisioning and `production` for TestFlight/App Store provisioning.
4. Deploy the functions. Each normal function validates the bearer token in its handler; `cleanup` has gateway JWT verification disabled because it accepts only `Bearer $CRON_SECRET` for the scheduled caller, and its handler rejects every other request.

   ```sh
   supabase functions deploy calls call-join call-end call-history push-token users-lookup cleanup rate-limit block-user unblock-user
   ```
5. In [HearMeOut/Secrets.swift](HearMeOut/Secrets.swift), set `supabaseURL` and `supabaseAnonKey` from Supabase's Connect dialog. Use only the anon/publishable key. Never use the service-role key or Agora App Certificate in iOS.
6. Open `HearMeOut.xcodeproj`. The checked-in project is generated from `project.yml`; regenerate after project-file changes with `xcodegen generate`. The target has `HearMeOut/Entitlements/HearMeOut.entitlements` configured as `CODE_SIGN_ENTITLEMENTS`. In Apple Developer, create an APNs auth key with VoIP capability, enable Push Notifications for the app ID, and make sure the provisioning profile/environment matches the deployment.

## Phone-to-simulator / two-phone test

1. Install the development build on a physical iPhone and run it on a simulator. Keep the simulator app in the foreground.
2. Create/confirm and sign into a different account on each device.
3. Save a distinct phone number on each account. Entering a 10-digit Indian number saves it as `+91` followed by those digits.
4. On either device, enter the other account's phone number (or copy/paste its user UUID) and press **Call**.
5. The caller should show **Ringing** until the callee joins. The simulator displays an in-app Answer/Decline screen; a physical iPhone uses PushKit/CallKit when APNs is configured.
6. Answer, verify both parties join and can exchange audio, captions, and Type & Speak output, then end from either side.

The legacy `channel-token` Edge Function remains deployed for compatibility,
but the app no longer calls it.

## Smoke tests

After deployment, use a real user access token without printing it in shell history or logs. The expected `/calls` responses are 404 for an unknown callee UUID, 400 for the caller's own UUID, and 200 with call/token fields for an existing different user. Also test `call-join`, `call-end`, `call-history`, and `push-token` with real authenticated requests. Run the Supabase security advisor after migrating and resolve any warnings it reports.

## Not yet verified on device

The project was built successfully for the generic iOS Simulator destination.
The call-create, call-join, and call-end Edge Function smoke flow was verified
with two authenticated test accounts. APNs delivery, PushKit/CallKit behavior,
and actual Agora audio still require a physical-device test.
