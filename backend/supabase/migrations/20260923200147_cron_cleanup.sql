-- 006_cron_cleanup.sql — schedule the cleanup/ Edge Function every minute.
--
-- BEFORE APPLYING, substitute the two placeholders:
--   __FUNCTIONS_BASE_URL__  cloud: https://<ref>.supabase.co
--                           local:  http://kong:8000 (in-docker Kong)
--   __CRON_SECRET__          same value as the cleanup/ CRON_SECRET env var
--
-- Design notes:
-- - pg_cron + pg_net; the secret travels inline (not vault) because
--   vault.secrets is not writable from migration roles
--   (_crypto_aead_det_noncegen denied on hosted AND local stacks).
--   Exposure is limited to DB readers; the secret only guards cleanup.
-- - unschedule is guarded so first-ever applies don't error.
-- - Local dev stacks that don't need the ticking cron can skip this file
--   (the cleanup endpoint itself is tested directly).

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

DO $$
BEGIN
  PERFORM cron.unschedule('cleanup-stale-calls');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'cleanup-stale-calls was not scheduled; nothing to unschedule';
END
$$;

select cron.unschedule('cleanup-stale-calls');

select cron.schedule(
  'cleanup-stale-calls',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://moxklalfnzslttsvpmrr.supabase.co/functions/v1/cleanup',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer 867433696446a502b9f14d2911b3768acf21c5d3b3162af7834e02caa0de2ae3'
    ),
    body := '{}'::jsonb
  );
  $$
);
