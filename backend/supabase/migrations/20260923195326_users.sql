-- 002_users.sql — public.users profile mirror.
--
-- Gap #1 fix: migration 001 references auth.users directly, and 003
-- (voip hardening) only ALTERs a `users` table that was never created.
-- On a fresh project 003 fails outright; everything that reads
-- `.from("users")` (calls/, push-token, push.ts, users-lookup) fails with it.
-- This migration runs first and owns the table; 003's
-- `ADD COLUMN IF NOT EXISTS` statements then become harmless no-ops.
--
-- One row per auth user, kept in sync by the on_auth_user_created trigger.
-- Phone numbers are stored as client-normalized E.164 strings and must be
-- UNIQUE so users-lookup has an unambiguous phone -> id mapping.

CREATE TABLE IF NOT EXISTS public.users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  phone TEXT UNIQUE,
  display_name TEXT,
  push_token TEXT,
  push_token_updated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_phone ON public.users(phone);

-- Keep updated_at fresh on row changes.
CREATE OR REPLACE FUNCTION public.update_users_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_users_updated_at ON public.users;
CREATE TRIGGER update_users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.update_users_updated_at();

-- Seed a profile row the moment an auth user is created, carrying the
-- display_name the client passed as user_metadata at signup. The client
-- fills in phone/display_name afterwards via an authenticated UPDATE
-- (owner RLS policy below), since e.g. email signup has no phone yet.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.users (id, phone, display_name)
  VALUES (
    NEW.id,
    NULLIF(NEW.phone, ''),
    NULLIF(NEW.raw_user_meta_data ->> 'display_name', '')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Backfill for users created before this migration ran (dev/test projects).
INSERT INTO public.users (id, phone, display_name)
SELECT u.id, NULLIF(u.phone, ''), NULLIF(u.raw_user_meta_data ->> 'display_name', '')
FROM auth.users u
ON CONFLICT (id) DO NOTHING;

-- RLS: owners manage their own row; service role (edge functions) has full
-- access, mirroring the policy pattern in 001_calls.sql.
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own profile" ON public.users;
CREATE POLICY "Users can view own profile"
  ON public.users FOR SELECT
  USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update own profile" ON public.users;
CREATE POLICY "Users can update own profile"
  ON public.users FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "Users can insert own profile" ON public.users;
CREATE POLICY "Users can insert own profile"
  ON public.users FOR INSERT
  WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "Service role full access to users" ON public.users;
CREATE POLICY "Service role full access to users"
  ON public.users FOR ALL
  USING (current_setting('request.jwt.claims', true)::json ->> 'role' = 'service_role');
