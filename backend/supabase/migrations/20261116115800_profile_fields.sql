-- 009_profile_fields.sql — the fields the app needs to restore a profile on
-- a new device, and to decide whether onboarding has been completed.
--
-- `communication_profile` doubles as the onboarding marker: it is NULL until
-- the user has picked how they prefer to communicate, and non-NULL
-- afterwards. A separate boolean would just be a second thing that can
-- disagree with the first.

ALTER TABLE public.users ADD COLUMN IF NOT EXISTS communication_profile TEXT;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS language TEXT DEFAULT 'en-IN';

COMMENT ON COLUMN public.users.communication_profile IS
  'How the user prefers to communicate (hearAndSpeak, hearOnly, partialHearing, speakOnly, textOnly). NULL means onboarding has not been completed for this account.';
COMMENT ON COLUMN public.users.language IS
  'BCP-47 language tag used for captions and text-to-speech. Defaults to en-IN.';
