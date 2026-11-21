# Backend tests (Layer 1)

## Layout

- `run-contract-tests.sh` — the suite. HTTP-only (curl + python3 + jq-free),
  parameterized by `BASE` + `ANON`. No tokens or project refs are hardcoded.
- `test-env.sh.template` — copy to `test-env.sh` (git-ignored) and fill in.

## Local stack (default target)

```sh
cd /path/to/backend
supabase init          # first time only (creates supabase/config.toml)
supabase start         # pulls images on first run (~2 GB); applies supabase/migrations
supabase functions serve --env-file supabase/functions/.env \
  calls call-join call-end call-history push-token users-lookup cleanup &
source tests/test-env.sh   # with ANON from `supabase status`
./tests/run-contract-tests.sh
```

`supabase/functions/.env` (git-ignored) needs, at minimum for the suite:

```
AGORA_APP_ID=<any 32-hex — token mint is real math, no network call>
AGORA_APP_CERTIFICATE=<any 32-hex>
CRON_SECRET=<a required secret — cleanup rejects requests unless it matches>
APNS_ENVIRONMENT=sandbox
```

APNs keys are NOT needed: with no device rows, `sendVoipPush` short-circuits
before touching APNs (`pushDelivered: false`, honest failure path).

Auth config for hermetic runs — `supabase/config.toml`:

```toml
[auth]
enable_signup = true
mailer_autoconfirm = true
```

This skips confirmation emails (no SMTP locally) so signups return sessions.

## Staging project

Same suite, different env. NEVER production: tests create users, calls, and
RLS probes. `BASE=https://<ref>.supabase.co ANON=<anon> ./run-contract-tests.sh`

## Coverage map (contract → edge function)

signup/trigger → 002 migration + handle_new_user · lookup hit/404/400/401 →
users-lookup · startCall fields/self/unknown → calls/ (+ rate-limit: hammer
11/min separately, not in the default run) · join/403/410 → call-join ·
end/missed/403 → call-end · history shape/pagination → call-history ·
push-token ok/400 + devices upsert → push-token · RLS read/update/anon/RPC →
001/002/004 policies · cleanup 405 (+ cron tick observed separately).
