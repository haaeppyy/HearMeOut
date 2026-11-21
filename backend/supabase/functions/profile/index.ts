/// Reads and writes the signed-in user's own profile.
///
/// Clients cannot write `public.users` directly — migration 008 removed those
/// policies — so this service-role function is the only way the app can
/// create or change its own profile.
///
/// Contract:
///   GET  /functions/v1/profile
///     Authorization: Bearer <supabase JWT>
///     200 { "id", "displayName", "phone", "communicationProfile", "language" }
///     401 { "error": "Unauthorized" }
///     404 { "error": "Profile not found" }
///     405 { "error": "Method not allowed" }
///
///   POST /functions/v1/profile
///     Authorization: Bearer <supabase JWT>
///     Body: any of { "display_name", "phone", "communication_profile", "language" }
///     200 { "id", "displayName", "phone", "communicationProfile", "language" }
///     400 { "error": "..." }      — a supplied field failed validation
///     401 { "error": "Unauthorized" }
///     409 { "error": "That phone number is already linked to another account" }
///     405 { "error": "Method not allowed" }
///
/// Only the fields present in the body are written, so a caller that wants
/// to change one thing does not have to resend the rest.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { normalizeE164 } from "../_shared/phone.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DEFAULT_LANGUAGE = "en-IN";

const VALID_COMMUNICATION_PROFILES = [
  "hearAndSpeak",
  "hearOnly",
  "partialHearing",
  "speakOnly",
  "textOnly",
];

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method !== "GET" && req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json({ error: "Unauthorized" }, 401);
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: userData, error: authError } = await supabase.auth.getUser(
    authHeader.slice("Bearer ".length)
  );
  if (authError || !userData.user) {
    return json({ error: "Unauthorized" }, 401);
  }
  const user = userData.user;

  if (req.method === "GET") {
    const { data: profile, error } = await supabase
      .from("users")
      .select("id, display_name, phone, communication_profile, language")
      .eq("id", user.id)
      .maybeSingle();

    if (error) {
      console.error("[profile] Failed to read profile:", error);
      return json({ error: "Failed to fetch profile" }, 500);
    }
    if (!profile) {
      return json({ error: "Profile not found" }, 404);
    }

    return json({
      id: profile.id,
      displayName: profile.display_name ?? null,
      phone: profile.phone ?? null,
      communicationProfile: profile.communication_profile ?? null,
      language: profile.language ?? DEFAULT_LANGUAGE,
    });
  }

  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const update: Record<string, string> = {};

  if ("phone" in body) {
    const phone = normalizeE164(body.phone);
    if (!phone) {
      return json(
        { error: "Phone must be in E.164 format, for example +14155552671" },
        400,
      );
    }
    update.phone = phone;
  }

  if ("display_name" in body) {
    const displayName = typeof body.display_name === "string"
      ? body.display_name.trim()
      : "";
    if (!displayName) {
      return json({ error: "display_name must not be empty" }, 400);
    }
    update.display_name = displayName;
  }

  if ("communication_profile" in body) {
    const profile = typeof body.communication_profile === "string"
      ? body.communication_profile.trim()
      : "";
    if (!VALID_COMMUNICATION_PROFILES.includes(profile)) {
      return json(
        { error: `communication_profile must be one of ${VALID_COMMUNICATION_PROFILES.join(", ")}` },
        400,
      );
    }
    update.communication_profile = profile;
  }

  if ("language" in body) {
    const language = typeof body.language === "string" ? body.language.trim() : "";
    if (!language) {
      return json({ error: "language must not be empty" }, 400);
    }
    update.language = language;
  }

  if (Object.keys(update).length === 0) {
    return json({ error: "Nothing to update" }, 400);
  }

  const { error } = await supabase
    .from("users")
    .upsert({ id: user.id, ...update }, { onConflict: "id" });

  if (error?.code === "23505") {
    return json(
      { error: "That phone number is already linked to another account" },
      409,
    );
  }
  if (error) {
    console.error("[profile] Failed to update profile:", error);
    return json({ error: "Failed to save profile" }, 500);
  }

  const { data: saved, error: readError } = await supabase
    .from("users")
    .select("id, display_name, phone, communication_profile, language")
    .eq("id", user.id)
    .maybeSingle();

  if (readError || !saved) {
    console.error("[profile] Failed to read back profile:", readError);
    return json({ error: "Failed to save profile" }, 500);
  }

  return json({
    id: saved.id,
    displayName: saved.display_name ?? null,
    phone: saved.phone ?? null,
    communicationProfile: saved.communication_profile ?? null,
    language: saved.language ?? DEFAULT_LANGUAGE,
  });
});
