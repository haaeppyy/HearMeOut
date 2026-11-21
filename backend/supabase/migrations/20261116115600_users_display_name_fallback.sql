-- Ensure profile names are useful even when the client did not provide a
-- display_name. This is safe for existing data: it only fills NULL/empty
-- values and does not modify an existing name.

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
    COALESCE(
      NULLIF(NEW.raw_user_meta_data ->> 'display_name', ''),
      NULLIF(split_part(NEW.email, '@', 1), '')
    )
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

UPDATE public.users AS profile
SET display_name = split_part(auth_user.email, '@', 1)
FROM auth.users AS auth_user
WHERE profile.id = auth_user.id
  AND NULLIF(profile.display_name, '') IS NULL
  AND NULLIF(split_part(auth_user.email, '@', 1), '') IS NOT NULL;

REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM anon, authenticated;
