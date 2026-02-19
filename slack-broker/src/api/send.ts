/**
 * Outbound message endpoint — POST /api/send
 *
 * Receives an encrypted message from a baudbot server, decrypts the body,
 * posts it to Slack, then zeroes the plaintext from memory.
 *
 * Request format (structured encryption — Option A from spec):
 * {
 *   "workspace_id": "T09192W1Z34",
 *   "action": "chat.postMessage" | "reactions.add" | "chat.update",
 *   "routing": {
 *     "channel": "C0A2G6TSDL6",
 *     "thread_ts": "1771464783.614839"  // optional
 *   },
 *   "encrypted_body": "<base64 crypto_box ciphertext>",
 *   "nonce": "<base64 nonce>",
 *   "timestamp": 1771465000,
 *   "signature": "<base64 ed25519 signature>"
 * }
 *
 * The broker:
 *   1. Verifies the server's signature
 *   2. Checks timestamp for replay protection
 *   3. Decrypts the body using crypto_box_open
 *   4. Posts to Slack using the appropriate API method
 *   5. Zeroes plaintext from memory
 */

import { boxDecrypt, zeroBytes } from "../crypto/box.js";
import { verify, canonicalizeOutbound } from "../crypto/verify.js";
import { decodeBase64, decodeUTF8 } from "../util/encoding.js";
import { getWorkspace } from "../routing/registry.js";
import { postMessage, addReaction, updateMessage } from "../slack/api.js";
import type { Env } from "../index.js";

const FIVE_MINUTES = 5 * 60;
const VALID_ACTIONS = ["chat.postMessage", "reactions.add", "chat.update"] as const;
type SlackAction = (typeof VALID_ACTIONS)[number];

interface SendRequest {
  workspace_id: string;
  action: string;
  routing: {
    channel: string;
    thread_ts?: string;
    timestamp?: string;  // for reactions.add and chat.update
    emoji?: string;      // for reactions.add
  };
  encrypted_body: string;
  nonce: string;
  timestamp: number;
  signature: string;
}

/**
 * Handle an outbound send request from a baudbot server.
 */
export async function handleSend(
  request: Request,
  env: Env,
): Promise<Response> {
  if (request.method !== "POST") {
    return jsonResponse({ ok: false, error: "method not allowed" }, 405);
  }

  let body: SendRequest;
  try {
    body = (await request.json()) as SendRequest;
  } catch {
    return jsonResponse({ ok: false, error: "invalid JSON" }, 400);
  }

  // Validate required fields
  if (
    !body.workspace_id ||
    !body.action ||
    !body.routing?.channel ||
    !body.encrypted_body ||
    !body.nonce ||
    !body.timestamp ||
    !body.signature
  ) {
    return jsonResponse({ ok: false, error: "missing required fields" }, 400);
  }

  // Validate action
  if (!VALID_ACTIONS.includes(body.action as SlackAction)) {
    return jsonResponse({ ok: false, error: `invalid action: ${body.action}` }, 400);
  }

  // Replay protection
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - body.timestamp) > FIVE_MINUTES) {
    return jsonResponse({ ok: false, error: "timestamp too old or too far in future" }, 400);
  }

  // Look up workspace
  const workspace = await getWorkspace(env.WORKSPACE_ROUTING, body.workspace_id);
  if (!workspace || workspace.status !== "active") {
    return jsonResponse({ ok: false, error: "workspace not active" }, 404);
  }

  // Verify server's signature on the request
  const canonical = canonicalizeOutbound(
    body.workspace_id,
    body.action,
    body.timestamp,
    body.encrypted_body,
  );
  const serverSigningPubkey = decodeBase64(workspace.server_signing_pubkey);
  const validSig = verify(canonical, body.signature, serverSigningPubkey);

  if (!validSig) {
    return jsonResponse({ ok: false, error: "invalid signature" }, 403);
  }

  // Decrypt the message body
  let decryptedBytes: Uint8Array;
  try {
    const senderPubkey = decodeBase64(workspace.server_pubkey);
    decryptedBytes = boxDecrypt(
      body.encrypted_body,
      body.nonce,
      senderPubkey,
      env.BROKER_PRIVATE_KEY_BYTES,
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : "decryption failed";
    return jsonResponse({ ok: false, error: message }, 400);
  }

  // Parse decrypted body
  let decryptedBody: Record<string, unknown>;
  try {
    decryptedBody = JSON.parse(decodeUTF8(decryptedBytes)) as Record<string, unknown>;
  } catch {
    zeroBytes(decryptedBytes);
    return jsonResponse({ ok: false, error: "decrypted body is not valid JSON" }, 400);
  }

  // Execute the Slack API call
  try {
    const result = await executeSlackAction(
      body.action as SlackAction,
      workspace.bot_token,
      body.routing,
      decryptedBody,
    );

    // Zero the plaintext immediately after posting
    zeroBytes(decryptedBytes);

    if (!result.ok) {
      return jsonResponse({ ok: false, error: result.error ?? "slack api error" }, 502);
    }

    return jsonResponse({ ok: true, ts: result.ts }, 200);
  } catch (err) {
    // Zero plaintext even on error
    zeroBytes(decryptedBytes);
    const message = err instanceof Error ? err.message : "unknown error";
    return jsonResponse({ ok: false, error: message }, 500);
  }
}

/**
 * Dispatch to the appropriate Slack API method.
 */
async function executeSlackAction(
  action: SlackAction,
  botToken: string,
  routing: SendRequest["routing"],
  decryptedBody: Record<string, unknown>,
): Promise<{ ok: boolean; ts?: string; error?: string }> {
  switch (action) {
    case "chat.postMessage":
      return postMessage(
        botToken,
        routing.channel,
        (decryptedBody.text as string) ?? "",
        {
          thread_ts: routing.thread_ts,
          blocks: decryptedBody.blocks as unknown[] | undefined,
        },
      );

    case "reactions.add":
      return addReaction(
        botToken,
        routing.channel,
        routing.timestamp ?? "",
        routing.emoji ?? (decryptedBody.emoji as string) ?? "",
      );

    case "chat.update":
      return updateMessage(
        botToken,
        routing.channel,
        routing.timestamp ?? "",
        (decryptedBody.text as string) ?? "",
        {
          blocks: decryptedBody.blocks as unknown[] | undefined,
        },
      );

    default:
      return { ok: false, error: `unsupported action: ${action}` };
  }
}

function jsonResponse(data: unknown, status: number): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
