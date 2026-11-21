-- Remove client INSERT/UPDATE policies on calls table as part of security hardening.
-- Every call must be created and updated through service-role edge functions to
-- enforce rate limiting, push notifications and to ensure no client can
-- inject arbitrary rows without the proper checks.

-- Drop the "Users can create calls" policy
DROP POLICY IF EXISTS "Users can create calls" ON public.calls;

-- Drop the "Users can update own calls" policy
DROP POLICY IF EXISTS "Users can update own calls" ON public.calls;

-- Note: The existing client policies also expose the channel to replay and
-- incorrect data, so removing them is safe.
