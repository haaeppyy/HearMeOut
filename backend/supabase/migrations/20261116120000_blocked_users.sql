-- Blocked contacts enforcement for HearMeOut calls
-- A contact can be blocked by the owner; blocked calls are silently recorded as missed.

CREATE TABLE IF NOT EXISTS public.blocked_users (
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    blocked_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, blocked_user_id)
);

COMMENT ON TABLE public.blocked_users IS
  'Enforce that a caller never rings the callee when the callee has them blocked. Incoming attempts are recorded as missed calls.';

-- Enable Row Level Security so the table is not publicly readable/writable
ALTER TABLE public.blocked_users ENABLE ROW LEVEL SECURITY;

-- Owner-only access: users can only insert, delete, or select their own rows.
CREATE POLICY "Blocked users own rows" ON public.blocked_users
    FOR ALL USING (
        auth.uid() = user_id
    );

-- Function to check if a caller is blocked by callee
CREATE OR REPLACE FUNCTION public.is_blocked(caller_uuid UUID, callee_uuid UUID)
    RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.blocked_users
        WHERE user_id = callee_uuid AND blocked_user_id = caller_uuid
    );
END;
$$ LANGUAGE plpgsql STABLE;
