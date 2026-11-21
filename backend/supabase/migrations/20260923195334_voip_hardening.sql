-- EchoSign Calls Migration 002 — VoIP hardening
--
-- 1. push_token columns on users (referenced by push.ts since the
--    beginning, but never actually created anywhere).
-- 2. 'missed' call status — distinct from 'failed'. An unanswered call is
--    normal call-history semantics, not an error condition; conflating
--    the two would misrepresent normal usage as failures in any
--    history/analytics view.
-- 3. Composite index for call-history queries (caller/callee + recency).
--
-- PSTN-specific columns from earlier iterations (route_type,
-- bridge_session_id, provider, provider_call_sid) are deliberately NOT
-- added back here — that work is shelved, not deleted; see project notes.
-- The base 001 schema's callee_phone/call_type columns are harmless to
-- leave in place for when PSTN work resumes.

ALTER TABLE users ADD COLUMN IF NOT EXISTS push_token TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS push_token_updated_at TIMESTAMPTZ;

-- NOTE: plain ADD VALUE (Postgres has no IF NOT EXISTS for enum values).
-- Safe on fresh projects; re-applying an already-migrated DB errors here.
ALTER TYPE call_status ADD VALUE 'missed';

CREATE INDEX IF NOT EXISTS idx_calls_history_caller
  ON calls(caller_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_calls_history_callee
  ON calls(callee_id, created_at DESC);

COMMENT ON COLUMN users.push_token IS
  'APNs VoIP push token, registered via the push-token endpoint. NULL means this user cannot receive incoming call notifications yet.';
