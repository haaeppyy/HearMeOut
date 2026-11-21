-- 004_devices.sql — per-device VoIP push tokens (Gap #2 follow-up).
--
-- Devices-only design (no users.push_token fallback — the project was empty,
-- so there is nothing to migrate): one row per (user, device token), which
-- supports multi-device rings and stops a second login from silently
-- orphaning the first device's token.
--
-- Presence (online/offline/in_call) is deliberately NOT here — that is a
-- Realtime subsystem, not a column written at token-registration time.
-- last_seen_at refreshes on every push-token registration.

CREATE TABLE IF NOT EXISTS public.devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  push_token TEXT NOT NULL UNIQUE,
  platform TEXT NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios', 'android')),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_devices_user_id ON public.devices(user_id);

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;

-- Owners can see their own device rows (future app surfaces, e.g. a
-- "signed-in devices" list). All writes go through the service-role edge
-- functions, never directly from clients.
DROP POLICY IF EXISTS "Users can view own devices" ON public.devices;
CREATE POLICY "Users can view own devices"
  ON public.devices FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Service role full access to devices" ON public.devices;
CREATE POLICY "Service role full access to devices"
  ON public.devices FOR ALL
  USING (current_setting('request.jwt.claims', true)::json ->> 'role' = 'service_role');
