-- EchoSign Calls Migration
-- Creates the call tracking tables for VoIP and PSTN calls.

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Call status enum
DO $$ BEGIN
    CREATE TYPE call_status AS ENUM (
        'created',
        'ringing',
        'bridging',
        'active',
        'ended',
        'failed'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Call type enum
DO $$ BEGIN
    CREATE TYPE call_type AS ENUM (
        'voip',
        'pstn'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Bridge status enum
DO $$ BEGIN
    CREATE TYPE bridge_status AS ENUM (
        'pending',
        'bot_joined',
        'dialing',
        'connected',
        'ended',
        'failed'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Calls table
CREATE TABLE IF NOT EXISTS calls (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    caller_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    callee_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    callee_phone TEXT,
    call_type call_type NOT NULL,
    status call_status NOT NULL DEFAULT 'created',
    agora_channel TEXT NOT NULL,
    agora_rtc_token TEXT,
    agora_rtm_token TEXT,
    caller_agora_uid INTEGER,
    callee_agora_uid INTEGER,
    provider TEXT,
    provider_call_sid TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at TIMESTAMPTZ,
    
    -- Validation: either callee_id (VoIP) or callee_phone (PSTN) must be set
    CONSTRAINT calls_contact_check CHECK (
        (call_type = 'voip' AND callee_id IS NOT NULL) OR
        (call_type = 'pstn' AND callee_phone IS NOT NULL)
    )
);

-- Call legs table (for tracking individual legs of a call)
CREATE TABLE IF NOT EXISTS call_legs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
    leg_type TEXT NOT NULL CHECK (leg_type IN ('caller', 'callee', 'bot')),
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    agora_uid INTEGER,
    provider TEXT,
    provider_call_sid TEXT,
    bridge_status bridge_status NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_calls_caller_id ON calls(caller_id);
CREATE INDEX IF NOT EXISTS idx_calls_callee_id ON calls(callee_id);
CREATE INDEX IF NOT EXISTS idx_calls_status ON calls(status);
CREATE INDEX IF NOT EXISTS idx_calls_created_at ON calls(created_at);
CREATE INDEX IF NOT EXISTS idx_call_legs_call_id ON call_legs(call_id);

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Triggers for updated_at
CREATE OR REPLACE TRIGGER update_calls_updated_at
    BEFORE UPDATE ON calls
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE OR REPLACE TRIGGER update_call_legs_updated_at
    BEFORE UPDATE ON call_legs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Row Level Security (RLS) policies
ALTER TABLE calls ENABLE ROW LEVEL SECURITY;
ALTER TABLE call_legs ENABLE ROW LEVEL SECURITY;

-- Users can see their own calls (as caller or callee)
CREATE POLICY "Users can view own calls" ON calls
    FOR SELECT USING (
        auth.uid() = caller_id OR 
        auth.uid() = callee_id
    );

-- Users can create calls they are the caller of
CREATE POLICY "Users can create calls" ON calls
    FOR INSERT WITH CHECK (
        auth.uid() = caller_id
    );

-- Users can update their own calls (for ending, etc.)
CREATE POLICY "Users can update own calls" ON calls
    FOR UPDATE USING (
        auth.uid() = caller_id OR 
        auth.uid() = callee_id
    );

-- Service role can do everything (for Edge Functions)
CREATE POLICY "Service role full access" ON calls
    FOR ALL USING (
        current_setting('request.jwt.claims', true)::json->>'role' = 'service_role'
    );

-- Call legs policies
CREATE POLICY "Users can view legs of own calls" ON call_legs
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM calls 
            WHERE calls.id = call_legs.call_id 
            AND (calls.caller_id = auth.uid() OR calls.callee_id = auth.uid())
        )
    );

CREATE POLICY "Service role full access to legs" ON call_legs
    FOR ALL USING (
        current_setting('request.jwt.claims', true)::json->>'role' = 'service_role'
    );

-- Cleanup function for stale calls (called by cron)
CREATE OR REPLACE FUNCTION cleanup_stale_calls()
RETURNS void AS $$
BEGIN
    UPDATE calls 
    SET status = 'failed', 
        updated_at = NOW(),
        ended_at = NOW()
    WHERE status IN ('created', 'ringing', 'bridging')
    AND created_at < NOW() - INTERVAL '60 seconds';
END;
$$ LANGUAGE plpgsql;
