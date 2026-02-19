/**
 * Server registration endpoint.
 *
 * A baudbot server calls POST /api/register to link itself to a workspace.
 * The request must include the auth_code from the OAuth flow to prove
 * workspace ownership.
 *
 * Flow:
 *   1. Server sends: workspace_id, server_pubkey, server_signing_pubkey,
 *      server_callback_url, auth_code
 *   2. Broker verifies auth_code against stored hash
 *   3. Broker activates the workspace with server details
 *   4. Broker returns its own public keys
 *
 * DELETE /api/register unlinks a server (requires server signature).
 */

import {
  getWorkspace,
  activateWorkspace,
  deactivateWorkspace,
  hashAuthCode,
} from "../routing/registry.js";
import { verify, canonicalizeOutbound } from "../crypto/verify.js";
import { decodeBase64, encodeBase64 } from "../util/encoding.js";
import type { Env } from "../index.js";

interface RegisterRequest {
  workspace_id: string;
  server_pubkey: string;
  server_signing_pubkey: string;
  server_callback_url: string;
  auth_code: string;
}

interface RegisterResponse {
  ok: boolean;
  broker_pubkey?: string;
  broker_signing_pubkey?: string;
  error?: string;
}

/**
 * Handle server registration.
 */
export async function handleRegister(
  request: Request,
  env: Env,
): Promise<Response> {
  if (request.method === "DELETE") {
    return handleUnregister(request, env);
  }

  if (request.method !== "POST") {
    return jsonResponse({ ok: false, error: "method not allowed" }, 405);
  }

  let body: RegisterRequest;
  try {
    body = (await request.json()) as RegisterRequest;
  } catch {
    return jsonResponse({ ok: false, error: "invalid JSON" }, 400);
  }

  // Validate required fields
  if (
    !body.workspace_id ||
    !body.server_pubkey ||
    !body.server_signing_pubkey ||
    !body.server_callback_url ||
    !body.auth_code
  ) {
    return jsonResponse({ ok: false, error: "missing required fields" }, 400);
  }

  // Validate workspace_id matches Slack team ID format to prevent
  // pipe-delimiter injection in canonicalized signatures.
  if (!/^T[A-Z0-9]+$/.test(body.workspace_id)) {
    return jsonResponse({ ok: false, error: "invalid workspace_id format" }, 400);
  }

  // Validate callback URL
  try {
    const url = new URL(body.server_callback_url);
    if (url.protocol !== "https:") {
      return jsonResponse({ ok: false, error: "callback URL must use HTTPS" }, 400);
    }
  } catch {
    return jsonResponse({ ok: false, error: "invalid callback URL" }, 400);
  }

  // Look up workspace
  const workspace = await getWorkspace(env.WORKSPACE_ROUTING, body.workspace_id);
  if (!workspace) {
    return jsonResponse({ ok: false, error: "workspace not found — complete OAuth install first" }, 404);
  }

  // Reject re-registration of already-active workspaces.
  // The current server must unregister first (DELETE /api/register).
  if (workspace.status === "active") {
    return jsonResponse({ ok: false, error: "workspace already active — unregister the current server first" }, 409);
  }

  // Verify auth code (must not be empty — cleared after first successful registration)
  if (!workspace.auth_code_hash) {
    return jsonResponse({ ok: false, error: "auth code already consumed — re-install the Slack app to generate a new one" }, 403);
  }

  const providedHash = await hashAuthCode(body.auth_code, env.BROKER_PRIVATE_KEY);
  if (providedHash !== workspace.auth_code_hash) {
    return jsonResponse({ ok: false, error: "invalid auth code" }, 403);
  }

  // Activate workspace
  const activated = await activateWorkspace(
    env.WORKSPACE_ROUTING,
    body.workspace_id,
    body.server_callback_url,
    body.server_pubkey,
    body.server_signing_pubkey,
  );

  if (!activated) {
    return jsonResponse({ ok: false, error: "failed to activate workspace" }, 500);
  }

  // Return broker's public keys
  const response: RegisterResponse = {
    ok: true,
    broker_pubkey: env.BROKER_PUBLIC_KEY,
    broker_signing_pubkey: env.BROKER_SIGNING_PUBLIC_KEY,
  };

  return jsonResponse(response, 200);
}

/**
 * Handle server unregistration (DELETE /api/register).
 *
 * Requires the server to sign the request to prove identity.
 */
async function handleUnregister(
  request: Request,
  env: Env,
): Promise<Response> {
  let body: { workspace_id: string; timestamp: number; signature: string };
  try {
    body = (await request.json()) as typeof body;
  } catch {
    return jsonResponse({ ok: false, error: "invalid JSON" }, 400);
  }

  if (!body.workspace_id || !body.timestamp || !body.signature) {
    return jsonResponse({ ok: false, error: "missing required fields" }, 400);
  }

  // Replay protection
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - body.timestamp) > 300) {
    return jsonResponse({ ok: false, error: "timestamp too old" }, 400);
  }

  // Look up workspace to get server's signing key
  const workspace = await getWorkspace(env.WORKSPACE_ROUTING, body.workspace_id);
  if (!workspace || workspace.status !== "active") {
    return jsonResponse({ ok: false, error: "workspace not active" }, 404);
  }

  // Verify server's signature
  const canonical = canonicalizeOutbound(
    body.workspace_id,
    "unregister",
    body.timestamp,
    "",
  );
  const serverSigningPubkey = decodeBase64(workspace.server_signing_pubkey);
  const valid = verify(canonical, body.signature, serverSigningPubkey);

  if (!valid) {
    return jsonResponse({ ok: false, error: "invalid signature" }, 403);
  }

  await deactivateWorkspace(env.WORKSPACE_ROUTING, body.workspace_id);
  return jsonResponse({ ok: true }, 200);
}

function jsonResponse(data: unknown, status: number): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
