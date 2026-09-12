/// SUPERSEDED — calls/index.ts now does a DB-backed rate limit check
/// directly against the `calls` table instead of calling this function.
/// This file's in-memory Map won't reliably persist across invocations in
/// a serverless environment (see README). Left in place in case you want
/// to repoint it at Redis and use it as a pre-check elsewhere, but it's
/// not part of the active PSTN call path anymore.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Rate limit configuration
const RATE_LIMIT_WINDOW_MS = 60 * 1000; // 1 minute window
const MAX_CALLS_PER_WINDOW = 5; // Maximum 5 PSTN calls per minute per user

interface RateLimitEntry {
  timestamps: number[];
}

// In-memory rate limit store (in production, use Redis)
const rateLimitStore: Map<string, RateLimitEntry> = new Map();

/**
 * Check if a user is within the rate limit for PSTN calls.
 */
function isWithinRateLimit(userId: string): { allowed: boolean; retryAfterMs?: number } {
  const now = Date.now();
  const entry = rateLimitStore.get(userId) || { timestamps: [] };

  // Remove timestamps outside the window
  const windowStart = now - RATE_LIMIT_WINDOW_MS;
  entry.timestamps = entry.timestamps.filter(ts => ts > windowStart);

  // Check if within limit
  if (entry.timestamps.length >= MAX_CALLS_PER_WINDOW) {
    const oldestInWindow = Math.min(...entry.timestamps);
    const retryAfterMs = oldestInWindow + RATE_LIMIT_WINDOW_MS - now;
    return { allowed: false, retryAfterMs };
  }

  // Add current timestamp
  entry.timestamps.push(now);
  rateLimitStore.set(userId, entry);

  return { allowed: true };
}

/**
 * Get the current rate limit status for a user.
 */
function getRateLimitStatus(userId: string): { remaining: number; resetMs: number } {
  const now = Date.now();
  const entry = rateLimitStore.get(userId) || { timestamps: [] };

  // Remove timestamps outside the window
  const windowStart = now - RATE_LIMIT_WINDOW_MS;
  const validTimestamps = entry.timestamps.filter(ts => ts > windowStart);

  const remaining = Math.max(0, MAX_CALLS_PER_WINDOW - validTimestamps.length);
  const resetMs = validTimestamps.length > 0 
    ? Math.max(0, Math.min(...validTimestamps) + RATE_LIMIT_WINDOW_MS - now)
    : 0;

  return { remaining, resetMs };
}

serve(async (req) => {
  // Only allow POST requests
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    
    // Verify authentication
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing authorization" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Check rate limit
    const { allowed, retryAfterMs } = isWithinRateLimit(user.id);

    if (!allowed) {
      const status = getRateLimitStatus(user.id);
      return new Response(
        JSON.stringify({
          error: "Rate limit exceeded",
          message: `Too many PSTN calls. Try again in ${Math.ceil((retryAfterMs || 0) / 1000)} seconds.`,
          retryAfterMs,
          remaining: status.remaining,
          resetMs: status.resetMs,
        }),
        {
          status: 429,
          headers: {
            "Content-Type": "application/json",
            "Retry-After": String(Math.ceil((retryAfterMs || 0) / 1000)),
            "X-RateLimit-Limit": String(MAX_CALLS_PER_WINDOW),
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": String(Math.ceil((status.resetMs) / 1000)),
          },
        }
      );
    }

    // Within rate limit
    const status = getRateLimitStatus(user.id);
    return new Response(
      JSON.stringify({
        allowed: true,
        remaining: status.remaining,
        resetMs: status.resetMs,
      }),
      {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          "X-RateLimit-Limit": String(MAX_CALLS_PER_WINDOW),
          "X-RateLimit-Remaining": String(status.remaining),
          "X-RateLimit-Reset": String(Math.ceil(status.resetMs / 1000)),
        },
      }
    );

  } catch (error) {
    console.error("[RateLimit] Error:", error);
    return new Response("Internal server error", { status: 500 });
  }
});
