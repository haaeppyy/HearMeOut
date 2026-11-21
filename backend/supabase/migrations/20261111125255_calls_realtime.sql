-- Deliver call INSERT/UPDATE events through Supabase Realtime. RLS on
-- public.calls remains the authorization boundary for subscribers.
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.calls;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END;
$$;
