/// Marks a call ended. Ownership-checked — only the caller or callee can
/// end their own call.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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
    .select("caller_id, callee_id, status")
    .eq("id", callId)
    .single();

  if (fetchError || !call) {
    return new Response(JSON.stringify({ error: "Call not found" }), { status: 404 });
  }
  if (call.caller_id !== userData.user.id && call.callee_id !== userData.user.id) {
    return new Response(JSON.stringify({ error: "Not your call" }), { status: 403 });
  }

  // A call that was still "ringing" when the caller hung up is a missed
  // call from the callee's perspective, not a generically "ended" one —
  // matters for call-history accuracy.
  const finalStatus = call.status === "ringing" ? "missed" : "ended";

  const { error: updateError } = await supabase
    .from("calls")
    .update({ status: finalStatus, ended_at: new Date().toISOString() })
    .eq("id", callId);

  if (updateError) {
    console.error("[CallEnd] Failed to update call:", updateError);
    return new Response(JSON.stringify({ error: "Failed to end call" }), { status: 500 });
  }

  return new Response(JSON.stringify({ ok: true, status: finalStatus }), {
    headers: { "Content-Type": "application/json" },
  });
});
