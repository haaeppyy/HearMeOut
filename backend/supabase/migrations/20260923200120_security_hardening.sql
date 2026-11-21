-- 005_security_hardening.sql — resolve supabase advisor WARNs.
-- 1. Pin search_path on SECURITY DEFINER / trigger functions.
-- 2. Revoke direct RPC execution of the signup trigger function from
--    anon/authenticated (the auth.users trigger itself is unaffected —
--    trigger invocation does not check EXECUTE privilege).

ALTER FUNCTION public.update_updated_at_column() SET search_path = public;
ALTER FUNCTION public.cleanup_stale_calls() SET search_path = public;
ALTER FUNCTION public.update_users_updated_at() SET search_path = public;

REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM anon, authenticated;
