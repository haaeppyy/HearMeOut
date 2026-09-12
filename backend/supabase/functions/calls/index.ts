/// Call creation endpoint — VoIP only for now (PSTN work is shelved, not
/// deleted; see project notes). Hardened beyond the original version:
/// validates the callee actually exists, blocks self-calls, and rate-limits
/// call attempts per caller — none of which existed before.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { RtcTokenBuilder, RtmTokenBuilder } from "https://esm.sh/agora-access-token@3";
import { sendVoipPush } from "../../../src/services/push.ts";

const AGORA_APP_ID = Deno.env.get("AGORA_APP_ID")!;
const AGORA_APP_CERTIFICATE = Deno.env.get("AGORA_APP_CERTIFICATE")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TOKEN_TTL_SECONDS = 3600;
const MAX_CALLS_PER_MINUTE = 10; // spam/harassment guard, not just cost control

interface CreateCallRequest {
  calleeId: string;
}

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
  const user = userData.user;

  const { calleeId }: CreateCallRequest = await req.json();
  if (!calleeId || typeof calleeId !== "string") {
    return new Response(JSON.stringify({ error: "calleeId required" }), { status: 400 });
  }
  if (calleeId === user.id) {
    return new Response(JSON.stringify({ error: "Cannot call yourself" }), { status: 400 });
  }

  // Confirm the callee is a real, existing user before ringing anything —
  // previously this went straight to token generation with no check, so a
  // typo'd or stale contact id would silently create a call that could
  // never be answered.
  const { data: callee, error: calleeError } = await supabase
    .from("users")
    .select("id")
    .eq("id", calleeId)
    .single();

  if (calleeError || !callee) {
    return new Response(JSON.stringify({ error: "Callee not found" }), { status: 404 });
  }

  // DB-backed rate limit — see the standalone `rate-limit` function's own
  // header note on why its in-memory store isn't trusted for this anymore.
  const rateLimitWindowStart = new Date(Date.now() - 60_000).toISOString();
  const { count: recentCalls } = await supabase
    .from("calls")
    .select("id", { count: "exact", head: true })
    .eq("caller_id", user.id)
    .gte("created_at", rateLimitWindowStart);

  if ((recentCalls ?? 0) >= MAX_CALLS_PER_MINUTE) {
    return new Response(
      JSON.stringify({ error: "Too many call attempts — try again shortly" }),
      { status: 429 }
    );
  }

  const agoraChannel = `call-${crypto.randomUUID()}`;
  const uid = Math.floor(Math.random() * 1_000_000);

  const rtcToken = RtcTokenBuilder.buildTokenWithUid(
    AGORA_APP_ID, AGORA_APP_CERTIFICATE, agoraChannel, uid, 1, TOKEN_TTL_SECONDS, TOKEN_TTL_SECONDS
  );
  const rtmToken = RtmTokenBuilder.buildToken(
    AGORA_APP_ID, AGORA_APP_CERTIFICATE, String(uid), 1, TOKEN_TTL_SECONDS
  );

  const { data: call, error: insertError } = await supabase
    .from("calls")
    .insert({
      caller_id: user.id,
      callee_id: calleeId,
      call_type: "voip",
      status: "ringing",
      agora_channel: agoraChannel,
      agora_rtc_token: rtcToken,
      agora_rtm_token: rtmToken,
      caller_agora_uid: uid,
    })
    .select()
    .single();

  if (insertError) {
    console.error("[Calls] Failed to create call:", insertError);
    return new Response(JSON.stringify({ error: "Failed to create call" }), { status: 500 });
  }

  const pushSent = await sendVoipPush(calleeId, {
    callId: call.id,
    channelName: agoraChannel,
    callerId: user.id,
    callerName: user.user_metadata?.display_name ?? "EchoSign user",
  });

  if (!pushSent) {
    // The call row exists and the caller can still see "ringing" state,
    // but the callee's phone almost certainly won't ring. Surfacing this
    // in the response (rather than only server-side logs) lets the client
    // show something more honest than an infinite ringing spinner.
    console.error(`[Calls] Push delivery failed for call ${call.id} to ${calleeId}`);
  }

  return new Response(
    JSON.stringify({
      callId: call.id,
      agoraChannel,
      rtcToken,
      rtmToken,
      uid,
      pushDelivered: pushSent,
    }),
    { headers: { "Content-Type": "application/json" } }
  );
});
