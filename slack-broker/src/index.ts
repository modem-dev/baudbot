/**
 * Slack Broker — Cloudflare Worker entry point.
 *
 * Routes incoming requests to the appropriate handler:
 *   POST /slack/events          — Slack Events API webhook
 *   GET  /slack/oauth/install   — Start OAuth install flow
 *   GET  /slack/oauth/callback  — Handle OAuth callback
 *   POST /api/register          — Register a baudbot server
 *   DELETE /api/register        — Unlink a baudbot server
 *   POST /api/send              — Outbound: encrypted message → Slack
 *   GET  /api/broker-pubkey     — Get broker's public keys
 *   GET  /health                — Health check
 */

import { handleSlackEvent } from "./slack/events.js";
import { handleOAuthInstall, handleOAuthCallback } from "./slack/oauth.js";
import { handleRegister } from "./api/register.js";
import { handleSend } from "./api/send.js";
import { decodeBase64, encodeBase64 } from "./util/encoding.js";
import nacl from "tweetnacl";

/**
 * Environment bindings available to the worker.
 */
export interface Env {
  // KV namespaces
  WORKSPACE_ROUTING: KVNamespace;
  OAUTH_STATE: KVNamespace;

  // Secrets (set via `wrangler secret put`)
  BROKER_PRIVATE_KEY: string;     // Base64-encoded X25519 private key (32-byte seed)
  SLACK_CLIENT_ID: string;
  SLACK_CLIENT_SECRET: string;
  SLACK_SIGNING_SECRET: string;

  // Derived at request time (not stored as secrets)
  BROKER_PUBLIC_KEY: string;          // Base64-encoded X25519 public key
  BROKER_SIGNING_PUBLIC_KEY: string;  // Base64-encoded Ed25519 public key
  BROKER_PRIVATE_KEY_BYTES: Uint8Array;
  BROKER_SIGNING_KEY: Uint8Array;     // Ed25519 secret key for signing envelopes

  // Execution context (for waitUntil)
  _ctx?: ExecutionContext;
}

/** Cloudflare KV namespace interface. */
interface KVNamespace {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
  delete(key: string): Promise<void>;
}

export default {
  async fetch(
    request: Request,
    rawEnv: Record<string, unknown>,
    ctx: ExecutionContext,
  ): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    // Derive keys from the secret seed
    const privateKeyBase64 = rawEnv.BROKER_PRIVATE_KEY as string;
    if (!privateKeyBase64) {
      return new Response("server misconfigured: missing BROKER_PRIVATE_KEY", { status: 500 });
    }

    const seed = decodeBase64(privateKeyBase64);
    const boxKeypair = nacl.box.keyPair.fromSecretKey(seed);
    const signKeypair = nacl.sign.keyPair.fromSeed(seed);

    // Build the full Env object
    const env: Env = {
      WORKSPACE_ROUTING: rawEnv.WORKSPACE_ROUTING as unknown as KVNamespace,
      OAUTH_STATE: rawEnv.OAUTH_STATE as unknown as KVNamespace,
      BROKER_PRIVATE_KEY: privateKeyBase64,
      SLACK_CLIENT_ID: rawEnv.SLACK_CLIENT_ID as string,
      SLACK_CLIENT_SECRET: rawEnv.SLACK_CLIENT_SECRET as string,
      SLACK_SIGNING_SECRET: rawEnv.SLACK_SIGNING_SECRET as string,
      BROKER_PUBLIC_KEY: encodeBase64(boxKeypair.publicKey),
      BROKER_SIGNING_PUBLIC_KEY: encodeBase64(signKeypair.publicKey),
      BROKER_PRIVATE_KEY_BYTES: boxKeypair.secretKey,
      BROKER_SIGNING_KEY: signKeypair.secretKey,
      _ctx: ctx,
    };

    // TODO(Phase 3): Add rate limiting before production deployment.
    // Per-workspace and per-IP limits on /api/send, /api/register, and /slack/events.
    // Cloudflare Rate Limiting rules or a KV-based token bucket are both viable.

    // Route requests
    try {
      // Health check
      if (path === "/health" && request.method === "GET") {
        return new Response(JSON.stringify({ ok: true, service: "slack-broker" }), {
          headers: { "Content-Type": "application/json" },
        });
      }

      // Broker public key endpoint
      if (path === "/api/broker-pubkey" && request.method === "GET") {
        return new Response(
          JSON.stringify({
            ok: true,
            broker_pubkey: env.BROKER_PUBLIC_KEY,
            broker_signing_pubkey: env.BROKER_SIGNING_PUBLIC_KEY,
          }),
          { headers: { "Content-Type": "application/json" } },
        );
      }

      // Slack Events API
      if (path === "/slack/events" && request.method === "POST") {
        return handleSlackEvent(request, env);
      }

      // OAuth install flow
      if (path === "/slack/oauth/install" && request.method === "GET") {
        return handleOAuthInstall(request, env);
      }

      // OAuth callback
      if (path === "/slack/oauth/callback" && request.method === "GET") {
        return handleOAuthCallback(request, env);
      }

      // Server registration
      if (path === "/api/register") {
        return handleRegister(request, env);
      }

      // Outbound message sending
      if (path === "/api/send" && request.method === "POST") {
        return handleSend(request, env);
      }

      // 404 for everything else
      return new Response("not found", { status: 404 });
    } catch (err) {
      // Never leak internal errors — log routing metadata only
      console.error(`[${request.method}] ${path} — unhandled error:`, err instanceof Error ? err.message : "unknown");
      return new Response("internal error", { status: 500 });
    }
  },
};
