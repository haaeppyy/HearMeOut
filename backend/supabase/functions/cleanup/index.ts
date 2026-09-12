/// Cleans up calls stuck in "ringing" past a reasonable timeout — the
/// callee never answered (or the push never arrived). Marked "missed",
/// not "failed", since from the callee's side this is a normal missed
/// call, not an error condition.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RING_TIMEOUT_SECONDS = 45; // typical "give up ringing" window

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const authHeader = req.headers.get("Authorization");
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (cronSecret && authHeader !== `Bearer ${cronSecret}`) {
    return new Response("Unauthorized", { status: 401 });
  }

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const cutoff = new Date(Date.now() - RING_TIMEOUT_SECONDS * 1000).toISOString();

    const { data: staleCalls, error: fetchError } = await supabase
      .from("calls")
      .select("id")
      .eq("status", "ringing")
      .lt("created_at", cutoff);

    if (fetchError) {
      console.error("[Cleanup] Failed to fetch stale calls:", fetchError);
      return new Response("Error fetching stale calls", { status: 500 });
    }

    if (!staleCalls || staleCalls.length === 0) {
      return new Response("No stale calls", { status: 200 });
    }

    const callIds = staleCalls.map((call) => call.id);
    const { error: updateError } = await supabase
      .from("calls")
      .update({ status: "missed", ended_at: new Date().toISOString() })
      .in("id", callIds);

    if (updateError) {
      console.error("[Cleanup] Failed to update stale calls:", updateError);
      return new Response("Error updating stale calls", { status: 500 });
    }

    console.log(`[Cleanup] Marked ${staleCalls.length} unanswered calls as missed`);
    return new Response(
      JSON.stringify({ success: true, markedMissed: staleCalls.length, callIds }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[Cleanup] Error:", error);
    return new Response("Internal server error", { status: 500 });
  }
});
