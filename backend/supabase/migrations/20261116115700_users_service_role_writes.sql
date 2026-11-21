-- Profiles are created by the auth trigger and subsequently maintained by
-- service-role Edge Functions. Authenticated clients may read only their own
-- profile; they must not be able to create or alter profile data directly.

DROP POLICY IF EXISTS "Users can update own profile" ON public.users;
DROP POLICY IF EXISTS "Users can insert own profile" ON public.users;
