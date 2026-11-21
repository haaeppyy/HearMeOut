-- Remove token columns from calls table as part of security hardening.
-- Tokens are now returned in the HTTP response and not stored on the device.
ALTER TABLE public.calls DROP COLUMN IF EXISTS agora_rtc_token;
ALTER TABLE public.calls DROP COLUMN IF EXISTS agora_rtm_token;
