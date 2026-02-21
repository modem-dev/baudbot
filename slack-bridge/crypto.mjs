/**
 * Cryptographic canonicalization utilities for broker bridge signing.
 *
 * Extracted from broker-bridge.mjs so they can be tested independently.
 */

function utf8Bytes(text) {
  return new TextEncoder().encode(text);
}

/**
 * Deterministic JSON serialization with sorted keys (recursive).
 * Compatible with npm `json-stable-stringify` for flat/nested objects.
 *
 * Matches JSON.stringify behavior for edge cases:
 * - undefined object values are omitted
 * - undefined array elements become null
 */
export function stableStringify(obj) {
  if (obj === null || typeof obj !== "object") return JSON.stringify(obj);
  if (Array.isArray(obj)) return "[" + obj.map((v) => stableStringify(v) ?? "null").join(",") + "]";
  const keys = Object.keys(obj).sort();
  const pairs = [];
  for (const k of keys) {
    const v = stableStringify(obj[k]);
    if (v !== undefined) pairs.push(JSON.stringify(k) + ":" + v);
  }
  return "{" + pairs.join(",") + "}";
}

/**
 * Construct the canonical bytes for envelope signing (inbound).
 *
 * Format: "workspace_id|timestamp|encrypted_payload_base64"
 */
export function canonicalizeEnvelope(workspace, timestamp, encrypted) {
  return utf8Bytes(`${workspace}|${timestamp}|${encrypted}`);
}

/**
 * Construct the canonical bytes for outbound request signing (inbox.pull, inbox.ack).
 *
 * Format: "workspace_id|action|timestamp|encrypted_body_base64"
 */
export function canonicalizeOutbound(workspace, action, timestamp, encryptedBody) {
  return utf8Bytes(`${workspace}|${action}|${timestamp}|${encryptedBody}`);
}

/**
 * Construct canonical bytes for /api/send request signing.
 *
 * Matches broker's `canonicalizeSendRequest()` — includes routing metadata
 * and nonce to prevent tampering of delivery targets or ciphertext replay
 * with modified metadata.
 *
 * Uses deterministic JSON serialization (sorted keys) so both sides produce
 * identical canonical bytes regardless of object key insertion order.
 */
export function canonicalizeSendRequest(ws, action, timestamp, encryptedBody, nonce, routing) {
  return utf8Bytes(
    stableStringify({
      workspace_id: ws,
      action,
      timestamp,
      encrypted_body: encryptedBody,
      nonce,
      routing: {
        channel: routing.channel,
        thread_ts: routing.thread_ts ?? "",
        timestamp: routing.timestamp ?? "",
        emoji: routing.emoji ?? "",
      },
    }),
  );
}
