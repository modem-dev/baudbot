/**
 * Signature creation and verification for envelope authentication.
 *
 * - The broker signs outbound envelopes (forwarded events) so servers can
 *   verify they came from the broker.
 * - Servers sign outbound requests so the broker can verify the sender.
 *
 * Uses Ed25519 (tweetnacl's sign module) for deterministic signatures.
 */

import nacl from "tweetnacl";
import { decodeBase64, encodeBase64 } from "../util/encoding.js";

/**
 * Sign a message with an Ed25519 secret key.
 *
 * @param message - the bytes to sign
 * @param secretKey - 64-byte Ed25519 secret key
 * @returns base64-encoded detached signature
 */
export function sign(message: Uint8Array, secretKey: Uint8Array): string {
  const signature = nacl.sign.detached(message, secretKey);
  return encodeBase64(signature);
}

/**
 * Verify a detached Ed25519 signature.
 *
 * @param message - the original message bytes
 * @param signatureBase64 - base64-encoded detached signature
 * @param publicKey - 32-byte Ed25519 public key
 * @returns true if signature is valid
 */
export function verify(
  message: Uint8Array,
  signatureBase64: string,
  publicKey: Uint8Array,
): boolean {
  try {
    const signature = decodeBase64(signatureBase64);
    return nacl.sign.detached.verify(message, signature, publicKey);
  } catch {
    return false;
  }
}

/**
 * Generate an Ed25519 signing keypair.
 *
 * @returns { publicKey, secretKey } — both as Uint8Arrays
 */
export function generateSigningKeypair(): nacl.SignKeyPair {
  return nacl.sign.keyPair();
}

/**
 * Construct the canonical bytes for envelope signing.
 *
 * Canonicalizes the envelope fields into a deterministic byte string
 * to prevent field-ordering or encoding ambiguities.
 *
 * Format: "workspace_id|timestamp|encrypted_payload_base64"
 */
export function canonicalizeEnvelope(
  workspaceId: string,
  timestamp: number,
  encryptedPayload: string,
): Uint8Array {
  const canonical = `${workspaceId}|${timestamp}|${encryptedPayload}`;
  return new TextEncoder().encode(canonical);
}

/**
 * Construct the canonical bytes for outbound request signing.
 *
 * Format: "workspace_id|action|timestamp|encrypted_body_base64"
 */
export function canonicalizeOutbound(
  workspaceId: string,
  action: string,
  timestamp: number,
  encryptedBody: string,
): Uint8Array {
  const canonical = `${workspaceId}|${action}|${timestamp}|${encryptedBody}`;
  return new TextEncoder().encode(canonical);
}
