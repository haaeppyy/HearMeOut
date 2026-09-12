/// Lets the callee fetch their own Agora RTC/RTM token to join a call
/// someone else already created. The original `/calls` endpoint only
/// issues a token for the caller's uid — the callee needs their own,
/// scoped to the same channel, once they actually answer. Without this,
/// there was no way for an answered incoming call to ever actually join
/// Agora, regardless of whether the push/CallKit UI worked.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { RtcTokenBuilder, RtmTokenBuilder } from "https://esm.sh/agora-access-token@3";

const AGORA_APP_ID = Deno.env.get("AGORA_APP_ID")!;
const AGORA_APP_CERTIFICATE = Deno.env.get("AGORA_APP_CERTIFICATE")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TOKEN_TTL_SECONDS = 3600;

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: userData, error: authError } = await supabase.auth.getUser(
    authHeader.replace("Bearer ", "")
  );
  if (authError || !userData?.user) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  const { callId } = await req.json();
  if (!callId) {
    return new Response(JSON.stringify({ error: "callId required" }), { status: 400 });
  }

  const { data: call, error: fetchError } = await supabase
    .from("calls")
    .select("callee_id, agora_channel, status")
    .eq("id", callId)
    .single();

  if (fetchError || !call) {
    return new Response(JSON.stringify({ error: "Call not found" }), { status: 404 });
  }
  // Only the callee can join via this endpoint — the caller already has
  // their token from /calls.
  if (call.callee_id !== userData.user.id) {
    return new Response(JSON.stringify({ error: "Not your call to join" }), { status: 403 });
  }
  if (call.status === "ended" || call.status === "missed" || call.status === "failed") {
    return new Response(JSON.stringify({ error: "This call is no longer active" }), { status: 410 });
  }

  const uid = Math.floor(Math.random() * 1_000_000);

  const rtcToken = RtcTokenBuilder.buildTokenWithUid(
    AGORA_APP_ID, AGORA_APP_CERTIFICATE, call.agora_channel, uid, 1, TOKEN_TTL_SECONDS, TOKEN_TTL_SECONDS
  );
  const rtmToken = RtmTokenBuilder.buildToken(
    AGORA_APP_ID, AGORA_APP_CERTIFICATE, String(uid), 1, TOKEN_TTL_SECONDS
  );

  // Best-effort — the call becomes "active" once the callee is actually
  // issued a token to join, which is a close-enough proxy for "answered"
  // without needing a separate explicit "answered" signal from the client.
  await supabase.from("calls").update({ status: "active", callee_agora_uid: uid }).eq("id", callId);

  return new Response(
    JSON.stringify({
      agoraChannel: call.agora_channel,
      rtcToken,
      rtmToken,
      uid,
    }),
    { headers: { "Content-Type": "application/json" } }
  );
});
