/**
 * Encrypt a Slack event and forward it to the registered server.
 *
 * Flow:
 *   1. Look up workspace → server_pubkey, server_url
 *   2. Encrypt the event payload with sealed box (server_pubkey)
 *   3. Sign the envelope with the broker's signing key
 *   4. POST the envelope to the server's callback URL
 *
 * If the server is unreachable, the event is dropped (no queuing).
 * The broker logs routing metadata (workspace_id, timestamp) but NEVER message content.
 */

import { sealedBoxEncrypt } from "../crypto/seal.js";
import { sign, canonicalizeEnvelope } from "../crypto/verify.js";
import { decodeBase64, encodeUTF8 } from "../util/encoding.js";
import type { WorkspaceRecord } from "./registry.js";

export interface ForwardEnvelope {
  workspace_id: string;
  encrypted: string;
  timestamp: number;
  signature: string;
}

export interface ForwardResult {
  ok: boolean;
  status?: number;
  error?: string;
}

/**
 * Encrypt and forward a Slack event to the registered server.
 *
 * @param event - the raw Slack event payload (JSON object)
 * @param workspace - the workspace routing record
 * @param brokerSigningKey - the broker's Ed25519 secret key for signing envelopes
 * @returns result indicating success/failure
 */
export async function forwardEvent(
  event: unknown,
  workspace: WorkspaceRecord,
  brokerSigningKey: Uint8Array,
): Promise<ForwardResult> {
  if (workspace.status !== "active") {
    return { ok: false, error: "workspace not active" };
  }

  if (!workspace.server_url || !workspace.server_pubkey) {
    return { ok: false, error: "workspace missing server configuration" };
  }

  // Serialize and encrypt
  const plaintext = encodeUTF8(JSON.stringify(event));
  const serverPubkey = decodeBase64(workspace.server_pubkey);
  const encrypted = await sealedBoxEncrypt(plaintext, serverPubkey);

  // Build and sign envelope
  const timestamp = Math.floor(Date.now() / 1000);
  const canonical = canonicalizeEnvelope(workspace.workspace_id, timestamp, encrypted);
  const signature = sign(canonical, brokerSigningKey);

  const envelope: ForwardEnvelope = {
    workspace_id: workspace.workspace_id,
    encrypted,
    timestamp,
    signature,
  };

  // Forward to server — fire and forget with timeout
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 10_000);

    const response = await fetch(workspace.server_url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Broker-Signature": signature,
        "X-Broker-Timestamp": String(timestamp),
      },
      body: JSON.stringify(envelope),
      signal: controller.signal,
    });

    clearTimeout(timeoutId);

    if (!response.ok) {
      return {
        ok: false,
        status: response.status,
        error: `server responded with ${response.status}`,
      };
    }

    return { ok: true, status: response.status };
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown error";
    return { ok: false, error: `forward failed: ${message}` };
  }
}
