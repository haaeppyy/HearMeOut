/// VoIP push notification service using APNs — real implementation.
///
/// This was a `console.log` stub for the entire session up to this point.
/// For a VoIP calling app, this is the single most load-bearing piece of
/// the backend: without it, a callee's phone never rings and CallKit's
/// `reportNewIncomingCall` never fires. Implemented directly against
/// Apple's documented HTTP/2 Provider API rather than a wrapper library —
/// Deno's `fetch` negotiates HTTP/2 automatically, and the JWT signing is
/// simple enough (ES256, one key) that a dependency isn't worth adding.
///
/// SETUP NEEDED (account/config, not code):
///   1. A VoIP Services certificate/key from Apple Developer portal —
///      specifically the .p8 auth key (Keys > VoIP Services), its Key ID,
///      and your Team ID.
///   2. Store the RAW CONTENTS of the .p8 file (the PEM text) as the
///      `APNS_PRIVATE_KEY` secret — not a file path. The previous version
///      of this file read `APNs_KEY_PATH` expecting a file on disk, which
///      doesn't make sense in a Supabase Edge Function (no persistent
///      custom filesystem to mount a secret onto) — this is genuinely
///      fixed now, not just renamed.
///   3. `APNS_BUNDLE_ID` should match your app's bundle id exactly (the
///      `.voip` suffix is appended automatically below, per Apple's
///      required topic format for VoIP pushes — don't include it yourself).
///   4. `APNS_ENVIRONMENT` = "production" or "sandbox". Get this wrong and
///      pushes silently fail against the other environment's devices.

import { create } from "https://deno.land/x/djwt@v3.0.2/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID")!;
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID")!;
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY")!; // full .p8 PEM contents
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID")!;
const APNS_ENVIRONMENT = Deno.env.get("APNS_ENVIRONMENT") ?? "sandbox"; // "production" | "sandbox"
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const APNS_HOST = APNS_ENVIRONMENT === "production"
  ? "api.push.apple.com"
  : "api.sandbox.push.apple.com";

interface VoipPushPayload {
  callId: string;
  channelName: string;
  callerId: string;
  callerName: string;
}

// Cached per-invocation-instance — best-effort only. Serverless isolates
// can cold-start on any request, so this isn't guaranteed to persist
// across calls, but it's a real optimization when the instance IS reused
// (Apple recommends not minting a token per-request; caching under 60min).
let cachedJwt: { token: string; expiresAt: number } | null = null;

async function importSigningKey(): Promise<CryptoKey> {
  const pemBody = APNS_PRIVATE_KEY
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const der = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}

async function getAuthToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && cachedJwt.expiresAt > now + 60) {
    return cachedJwt.token;
  }

  const key = await importSigningKey();
  const token = await create(
    { alg: "ES256", kid: APNS_KEY_ID },
    { iss: APNS_TEAM_ID, iat: now },
    key
  );

  cachedJwt = { token, expiresAt: now + 50 * 60 }; // refresh before Apple's 60min limit
  return token;
}

/**
 * Send a VoIP push notification to a user's device via Apple's HTTP/2
 * Provider API.
 */
export async function sendVoipPush(userId: string, payload: VoipPushPayload): Promise<boolean> {
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: user, error } = await supabase
    .from("users")
    .select("push_token")
    .eq("id", userId)
    .single();

  if (error || !user?.push_token) {
    console.error(`[Push] No push token on file for user ${userId} — cannot ring their device`);
    return false;
  }

  try {
    const jwt = await getAuthToken();

    const response = await fetch(`https://${APNS_HOST}/3/device/${user.push_token}`, {
      method: "POST",
      headers: {
        "authorization": `bearer ${jwt}`,
        "apns-topic": `${APNS_BUNDLE_ID}.voip`,
        "apns-push-type": "voip",
        "apns-priority": "10",
        "apns-expiration": "0",
      },
      body: JSON.stringify({
        aps: { "content-available": 1 },
        callId: payload.callId,
        channelName: payload.channelName,
        callerId: payload.callerId,
        callerName: payload.callerName,
      }),
    });

    if (response.ok) {
      return true;
    }

    const body = await response.json().catch(() => ({}));
    console.error(`[Push] APNs rejected push for ${userId}: ${response.status} ${body.reason ?? ""}`);

    // Self-healing: a token that's actually gone (uninstalled, reset)
    // shouldn't keep being retried forever — clear it so the next call
    // attempt fails fast instead of silently no-op'ing against a dead
    // token every time.
    if (response.status === 410 || body.reason === "BadDeviceToken" || body.reason === "Unregistered") {
      await supabase.from("users").update({ push_token: null }).eq("id", userId);
      console.log(`[Push] Cleared stale push token for user ${userId}`);
    }

    return false;
  } catch (error) {
    console.error(`[Push] Failed to send VoIP push to ${userId}:`, error);
    return false;
  }
}

/**
 * Store or update a user's device push token. Called when the app
 * registers for VoIP pushes (typically on launch / PKPushRegistry delegate
 * callback).
 */
export async function storePushToken(userId: string, pushToken: string): Promise<boolean> {
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { error } = await supabase
      .from("users")
      .upsert(
        { id: userId, push_token: pushToken, push_token_updated_at: new Date().toISOString() },
        { onConflict: "id" }
      );

    if (error) {
      console.error("[Push] Failed to store push token:", error);
      return false;
    }
    return true;
  } catch (error) {
    console.error("[Push] Failed to store push token:", error);
    return false;
  }
}
