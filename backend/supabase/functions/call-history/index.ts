/// Returns recent calls for the authenticated user, as caller or callee.
/// A calling app without any call-history surface isn't really finished —
/// this was entirely absent before.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  if (req.method !== "GET") {
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

  const url = new URL(req.url);
  const limit = Math.min(Number(url.searchParams.get("limit")) || 50, 100);
  const before = url.searchParams.get("before"); // ISO timestamp, for pagination

  let query = supabase
    .from("calls")
    .select("id, caller_id, callee_id, status, created_at, ended_at")
    .eq("call_type", "voip")
    .or(`caller_id.eq.${userData.user.id},callee_id.eq.${userData.user.id}`)
    .order("created_at", { ascending: false })
    .limit(limit);

  if (before) {
    query = query.lt("created_at", before);
  }

  const { data: calls, error } = await query;

  if (error) {
    console.error("[CallHistory] Query failed:", error);
    return new Response(JSON.stringify({ error: "Failed to fetch call history" }), { status: 500 });
  }

  const entries = (calls ?? []).map((call) => ({
    callId: call.id,
    direction: call.caller_id === userData.user.id ? "outgoing" : "incoming",
    otherPartyId: call.caller_id === userData.user.id ? call.callee_id : call.caller_id,
    status: call.status, // includes 'missed' now — see migration 002
    startedAt: call.created_at,
    endedAt: call.ended_at,
  }));

  return new Response(JSON.stringify({ calls: entries }), {
    headers: { "Content-Type": "application/json" },
  });
});
