/// Registers the device's APNs VoIP push token. Call this from
/// `PushKitManager.pushRegistry(_:didUpdate:for:)` on the iOS side —
/// without this endpoint, `storePushToken` in push.ts existed but had
/// nothing calling it from outside the codebase.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { storePushToken } from "../../../src/services/push.ts";

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

  const { pushToken } = await req.json();
  if (!pushToken || typeof pushToken !== "string" || pushToken.length < 16) {
    return new Response(JSON.stringify({ error: "Valid pushToken required" }), { status: 400 });
  }

  const ok = await storePushToken(userData.user.id, pushToken);
  if (!ok) {
    return new Response(JSON.stringify({ error: "Failed to store push token" }), { status: 500 });
  }

  return new Response(JSON.stringify({ ok: true }), {
    headers: { "Content-Type": "application/json" },
  });
});
