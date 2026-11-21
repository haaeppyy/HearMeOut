/// Returns recent calls for the authenticated user, as caller or callee.
/// A calling app without any call-history surface isn't really finished —
/// this was entirely absent before.
///
/// The response carries enough about the other party for the device to
/// reconcile what happened while the app was closed: their id, their
/// phone number and their name.

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
    .select(
      "id, caller_id, callee_id, status, created_at, answered_at, ended_at, " +
        "caller_display_name, caller_phone",
    )
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

  // The other party's details. The service role can read any profile row,
  // but for an incoming call the snapshot taken at the time is the more
  // honest answer — it is who the caller was when they called.
  const otherIds = [
    ...new Set(
      (calls ?? [])
        .map((call) =>
          call.caller_id === userData.user.id ? call.callee_id : call.caller_id
        )
        .filter((id): id is string => Boolean(id)),
    ),
  ];

  const othersById = new Map<string, { phone: string | null; display_name: string | null }>();
  if (otherIds.length > 0) {
    const { data: others } = await supabase
      .from("users")
      .select("id, phone, display_name")
      .in("id", otherIds);
    for (const other of others ?? []) {
      othersById.set(other.id, {
        phone: other.phone ?? null,
        display_name: other.display_name ?? null,
      });
    }
  }

  const entries = (calls ?? []).map((call) => {
    const isIncoming = call.caller_id !== userData.user.id;
    const otherPartyId = isIncoming ? call.caller_id : call.callee_id;
    const other = otherPartyId ? othersById.get(otherPartyId) : undefined;
    return {
      callId: call.id,
      direction: isIncoming ? "incoming" : "outgoing",
      otherPartyId: otherPartyId ?? null,
      otherParty: {
        id: otherPartyId ?? null,
        phone: (isIncoming ? call.caller_phone : other?.phone) ?? null,
        displayName:
          (isIncoming ? call.caller_display_name : other?.display_name) ?? null,
      },
      status: call.status, // includes 'missed' and 'declined'
      startedAt: call.created_at,
      connectedAt: call.answered_at,
      endedAt: call.ended_at,
    };
  });

  return new Response(JSON.stringify({ calls: entries }), {
    headers: { "Content-Type": "application/json" },
  });
});
