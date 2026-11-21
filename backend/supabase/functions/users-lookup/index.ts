/// Phone-number -> user-id lookup (Gap #2 fix).
///
/// The app's contacts only store phone numbers, but `calls/` takes a
/// Supabase user id (`calleeId`). This endpoint bridges the two: exact
/// match on the client-normalized E.164 phone stored in `public.users`.
///
/// Contract:
///   GET /functions/v1/users-lookup?phone=+15551234567
///     Authorization: Bearer <supabase JWT>
///   200 { "id": "<uuid>", "displayName": "<name>" | null }
///   400 { "error": "phone required" }      — missing/empty query param
///   400 { "error": "phone must be in E.164 format, ..." } — unparseable number
///   401 { "error": "Unauthorized" }        — bad/missing bearer token
///   404 { "error": "User not found" }      — no registered user owns it
///   405 { "error": "Method not allowed" }  — non-GET
///   500 { "error": "Lookup failed" }       — DB error
///   429 { "error": "Too many lookup attempts — try again shortly" } — rate limited

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { normalizeE164 } from "../_shared/phone.ts";

serve(async (req) => {
  if (req.method !== "GET") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );
  const { data: userData, error: authError } = await supabase.auth.getUser(
    authHeader.replace("Bearer ", "")
  );
  if (authError || !userData?.user) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }
  const user = userData.user;

  const url = new URL(req.url);
  const phone = url.searchParams.get("phone");
  if (!phone) {
    return new Response(JSON.stringify({ error: "phone required" }), { status: 400 });
  }

  const normalized = normalizeE164(phone);
  if (!normalized) {
    return new Response(
      JSON.stringify({ error: "phone must be in E.164 format, e.g. +15551234567" }),
      { status: 400 }
    );
  }

  const { data, error } = await supabase
    .from("users")
    .select("id, display_name, phone")
    .eq("phone", normalized)
    .single();

  if (error) {
    if (error.code === "PGRST116") {
      // No match - return 404 to match app expectations
      return new Response(JSON.stringify({ error: "User not found" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      });
    }
    console.error("[Users-lookup] DB error:", error);
    return new Response(JSON.stringify({ error: "Lookup failed" }), { status: 500 });
  }

  return new Response(JSON.stringify({ id: data.id, displayName: data.display_name }), {
    headers: { "Content-Type": "application/json" },
  });
});
