/// Block a user so that they cannot start outgoing or incoming calls.
///
/// This is the reverse of unblock-user: no new call can be created, and
/// existing ringing calls that the blocked user is involved in (caller or
/// callee) are silently terminated for the blocked side.

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
  const blocker = userData.user;

  const { blockedId }: { blockedId: string } = await req.json();
  if (!blockedId || typeof blockedId !== "string") {
    return new Response(JSON.stringify({ error: "blockedId required" }), { status: 400 });
  }

  // Block -> only the owner can block others, not themselves
  if (blockedId === blocker.id) {
    return new Response(JSON.stringify({ error: "Cannot block yourself" }), { status: 400 });
  }

  const { data: blockedUser } = await supabase
    .from("users")
    .select("id")
    .eq("id", blockedId)
    .maybeSingle();
  if (!blockedUser) {
    return new Response(JSON.stringify({ error: "Blocked user not found" }), { status: 404 });
  }

  // Insert the relationship
  const { data, error } = await supabase
    .from("blocked_users")
    .insert({ user_id: blocker.id, blocked_user_id: blockedId })
    .select()
    .single();

  if (error) {
    console.error("[Block-user] Insert error:", error);
    return new Response(
      JSON.stringify({ error: "Failed to block user" }),
      { status: 500 }
    );
  }

  // Terminate any incoming ringing call from the blocked user to the blocker
  const { error: updateError } = await supabase
    .from("calls")
    .update({ status: "missed" })
    .eq("caller_id", blockedId)
    .eq("callee_id", blocker.id)
    .eq("status", "ringing");

  if (updateError) {
    console.error("[Block-user] Failed to terminate ringing calls:", updateError);
  }

  return new Response(
    JSON.stringify({ blockedUser: data }),
    { headers: { "Content-Type": "application/json" } }
  );
});
