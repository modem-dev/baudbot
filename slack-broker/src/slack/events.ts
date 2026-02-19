/**
 * Slack Events API handler.
 *
 * Responsibilities:
 *   1. Verify Slack request signatures (HMAC-SHA256)
 *   2. Handle url_verification challenge (Slack app setup)
 *   3. Parse event payloads and dispatch to the forwarding pipeline
 *
 * Replay protection: reject events with timestamps older than 5 minutes.
 */

import { getWorkspace } from "../routing/registry.js";
import { forwardEvent } from "../routing/forward.js";
import type { Env } from "../index.js";

const FIVE_MINUTES = 5 * 60;

/**
 * Verify a Slack request signature.
 *
 * Slack signs requests with HMAC-SHA256 using the signing secret.
 * See: https://api.slack.com/authentication/verifying-requests-from-slack
 *
 * @param signingSecret - the app's signing secret
 * @param timestamp - X-Slack-Request-Timestamp header
 * @param body - raw request body string
 * @param signature - X-Slack-Signature header (v0=...)
 * @returns true if the signature is valid and timestamp is fresh
 */
export async function verifySlackSignature(
  signingSecret: string,
  timestamp: string,
  body: string,
  signature: string,
): Promise<boolean> {
  // Replay protection: reject timestamps older than 5 minutes
  const ts = parseInt(timestamp, 10);
  if (isNaN(ts)) return false;

  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - ts) > FIVE_MINUTES) return false;

  // Compute expected signature
  const sigBasestring = `v0:${timestamp}:${body}`;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(signingSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(sigBasestring));
  const expected = `v0=${Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")}`;

  // Constant-time comparison
  if (expected.length !== signature.length) return false;
  let mismatch = 0;
  for (let i = 0; i < expected.length; i++) {
    mismatch |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  }
  return mismatch === 0;
}

interface SlackChallenge {
  type: "url_verification";
  challenge: string;
  token: string;
}

interface SlackEventCallback {
  type: "event_callback";
  team_id: string;
  event: {
    type: string;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

type SlackPayload = SlackChallenge | SlackEventCallback;

/**
 * Handle an incoming Slack Events API request.
 */
export async function handleSlackEvent(
  request: Request,
  env: Env,
): Promise<Response> {
  // Read and verify signature
  const body = await request.text();
  const timestamp = request.headers.get("X-Slack-Request-Timestamp") ?? "";
  const signature = request.headers.get("X-Slack-Signature") ?? "";

  const valid = await verifySlackSignature(
    env.SLACK_SIGNING_SECRET,
    timestamp,
    body,
    signature,
  );

  if (!valid) {
    return new Response("invalid signature", { status: 401 });
  }

  // Parse payload
  let payload: SlackPayload;
  try {
    payload = JSON.parse(body) as SlackPayload;
  } catch {
    return new Response("invalid JSON", { status: 400 });
  }

  // Handle url_verification challenge
  if (payload.type === "url_verification") {
    return new Response(JSON.stringify({ challenge: (payload as SlackChallenge).challenge }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  // Handle event callbacks
  if (payload.type === "event_callback") {
    const eventPayload = payload as SlackEventCallback;
    const workspaceId = eventPayload.team_id;

    if (!workspaceId) {
      return new Response("missing team_id", { status: 400 });
    }

    // Look up workspace routing
    const workspace = await getWorkspace(env.WORKSPACE_ROUTING, workspaceId);

    if (!workspace || workspace.status !== "active") {
      // ACK the event but don't forward — no active server
      return new Response("ok", { status: 200 });
    }

    // Forward asynchronously — ACK Slack immediately (3-second deadline)
    // Use waitUntil to continue processing after responding
    const brokerSigningKey = env.BROKER_SIGNING_KEY;

    if (brokerSigningKey) {
      const forwardPromise = forwardEvent(
        eventPayload,
        workspace,
        brokerSigningKey,
      );

      // If we have a ctx for waitUntil, use it; otherwise fire-and-forget
      if (env._ctx) {
        env._ctx.waitUntil(forwardPromise);
      }
    }

    return new Response("ok", { status: 200 });
  }

  return new Response("unknown event type", { status: 400 });
}
