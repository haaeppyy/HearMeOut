/// Unblock a user so that they can start outgoing and incoming calls again.
///
/// Reverses block-user: removes the relationship and has no further side effects.

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

  // Only the owner of the block can unblock
  const { data: relationship, error } = await supabase
    .from("blocked_users")
    .select("*")
    .eq("user_id", blocker.id)
    .eq("blocked_user_id", blockedId)
    .maybeSingle();

  if (!relationship) {
    // Not blocked; a no-op but still success to keep callers happy.
    return new Response(
      JSON.stringify({ message: "User is not blocked" }),
      { headers: { "Content-Type": "application/json" } }
    );
  }

  const { error: deleteError } = await supabase
    .from("blocked_users")
    .delete()
    .eq("user_id", blocker.id)
    .eq("blocked_user_id", blockedId);

  if (deleteError) {
    console.error("[Unblock-user] Delete error:", deleteError);
    return new Response(
      JSON.stringify({ error: "Failed to unblock user" }),
      { status: 500 }
    );
  }

  return new Response(
    JSON.stringify({ message: "User unblocked" }),
    { headers: { "Content-Type": "application/json" } }
  );
});
