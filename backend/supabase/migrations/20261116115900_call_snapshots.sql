-- 010_call_snapshots.sql — who called, and what happened to the call.
--
-- The callee's device has to show the caller's name and phone number when
-- the phone rings, and it cannot look them up: the profile table only lets
-- a signed-in user read their own row. So the caller's details are
-- snapshotted onto the call itself when it is created, and travel with the
-- push and the Realtime event.
--
-- `answered_at` records when the call was actually answered, which is not
-- the same as when it started ringing.

-- A call the other party deliberately turned away, as distinct from one
-- that rang and was never picked up.
ALTER TYPE call_status ADD VALUE 'declined';

ALTER TABLE public.calls ADD COLUMN IF NOT EXISTS caller_display_name TEXT;
ALTER TABLE public.calls ADD COLUMN IF NOT EXISTS caller_phone TEXT;
ALTER TABLE public.calls ADD COLUMN IF NOT EXISTS answered_at TIMESTAMPTZ;

COMMENT ON COLUMN public.calls.caller_display_name IS
  'The caller''s display name at the time of the call. Snapshotted so the callee can be shown who is calling without being able to read other users'' profiles.';
COMMENT ON COLUMN public.calls.caller_phone IS
  'The caller''s phone number at the time of the call, in E.164. Snapshotted for the same reason as caller_display_name.';
COMMENT ON COLUMN public.calls.answered_at IS
  'When the call was answered. NULL means it was still ringing, or was never answered.';
