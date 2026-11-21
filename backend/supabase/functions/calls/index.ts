/// Call creation endpoint — VoIP only for now (PSTN work is shelved, not
/// deleted; see project notes). Hardened beyond the original version:
/// validates the callee actually exists, blocks self-calls, and rate-limits
/// call attempts per caller — none of which existed before.
///
/// Cleanup: stale calls are now removed by the `cleanup` edge function; the
/// older `cleanup_stale_calls()` function is no longer scheduled.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { RtcTokenBuilder, RtmTokenBuilder } from "https://esm.sh/agora-access-token@2";
import { sendVoipPush } from "../_shared/push.ts";

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

  // Confirm the callee is a real, existing user before ringing anything.
  // Without this an unknown id reaches the insert, trips the foreign key and
  // comes back as a 500 instead of a clean 404.
  const { data: callee, error: calleeError } = await supabase
    .from("users")
    .select("id")
    .eq("id", calleeId)
    .maybeSingle();

  if (calleeError) {
    console.error("[Calls] Callee lookup failed:", calleeError);
    return new Response(JSON.stringify({ error: "Callee lookup failed" }), { status: 500 });
  }
  if (!callee) {
    return new Response(JSON.stringify({ error: "Callee not found" }), { status: 404 });
  }

  // Check if caller is blocked by callee
  const { data: blocked } = await supabase
    .from("blocked_users")
    .select("user_id")
    .eq("user_id", calleeId)
    .eq("blocked_user_id", user.id)
    .maybeSingle();

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
  // Agora reserves UID 0 for automatic assignment. Keep every caller UID
  // explicit so the client and token are always unambiguous.
  const uid = Math.floor(Math.random() * 1_000_000) + 1;

  // Snapshot who is calling onto the call itself. The callee's device
  // cannot read the caller's profile row — RST only lets a signed-in user
  // read their own — so these details have to travel with the call for the
  // phone to be able to say who is ringing.
  const { data: callerProfile } = await supabase
    .from("users")
    .select("display_name, phone")
    .eq("id", user.id)
    .maybeSingle();

  const callerDisplayName =
    callerProfile?.display_name
    ?? user.user_metadata?.display_name
    ?? "HearMeOut user";
  const callerPhone = callerProfile?.phone ?? null;

  // Agora expects absolute Unix timestamps here, not a relative duration.
  const tokenExpiresAt = Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS;
  const rtcToken = RtcTokenBuilder.buildTokenWithUid(
    AGORA_APP_ID, AGORA_APP_CERTIFICATE, agoraChannel, uid, 1, tokenExpiresAt, tokenExpiresAt
  );
  const rtmToken = RtmTokenBuilder.buildToken(
    AGORA_APP_ID, AGORA_APP_CERTIFICATE, String(uid), 1, tokenExpiresAt
  );

  const { data: call, error: insertError } = await supabase
    .from("calls")
    .insert({
      caller_id: user.id,
      callee_id: calleeId,
      call_type: "voip",
      status: blocked ? "missed" : "ringing",
      agora_channel: agoraChannel,
      caller_agora_uid: uid,
      caller_display_name: callerDisplayName,
      caller_phone: callerPhone,
    })
    .select()
    .single();

  if (insertError) {
    console.error("[Calls] Failed to create call:", insertError);
    return new Response(JSON.stringify({ error: "Failed to create call" }), { status: 500 });
  }

  let pushSent = false;
  if (!blocked) {
    pushSent = await sendVoipPush(calleeId, {
      callId: call.id,
      channelName: agoraChannel,
      callerId: user.id,
      callerName: callerDisplayName,
      callerPhone: callerPhone ?? "",
    });

    if (!pushSent) {
      console.error(`[Calls] Push delivery failed for call ${call.id} to ${calleeId}`);
    }
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
