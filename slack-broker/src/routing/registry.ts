/**
 * KV-backed workspace routing registry.
 *
 * Maps workspace_id → { server_url, server_pubkey, bot_token, status }.
 * Stored in the WORKSPACE_ROUTING KV namespace.
 *
 * Status lifecycle: pending → active → (optionally) inactive
 *   - pending: OAuth complete, no server linked yet
 *   - active: server registered and verified
 *   - inactive: server unlinked or heartbeat timed out
 */

import nacl from "tweetnacl";
import { encodeBase64, decodeBase64 } from "../util/encoding.js";

export type WorkspaceStatus = "pending" | "active" | "inactive";

export interface WorkspaceRecord {
  workspace_id: string;
  team_name: string;
  server_url: string;
  /** Base64-encoded X25519 public key for sealing inbound messages. */
  server_pubkey: string;
  /** Base64-encoded Ed25519 public key for verifying server signatures. */
  server_signing_pubkey: string;
  /** Encrypted bot token (encrypted at rest in KV). */
  bot_token: string;
  status: WorkspaceStatus;
  /** ISO 8601 timestamp of last registration or heartbeat. */
  updated_at: string;
  /** Auth code hash — used during registration to verify workspace ownership. */
  auth_code_hash: string;
}

/** KV binding type for Cloudflare Workers. */
export interface KVNamespace {
  get(key: string, options?: { type?: string }): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
  delete(key: string): Promise<void>;
}

/**
 * Get a workspace record from KV.
 */
export async function getWorkspace(
  kv: KVNamespace,
  workspaceId: string,
): Promise<WorkspaceRecord | null> {
  const raw = await kv.get(`workspace:${workspaceId}`);
  if (!raw) return null;
  return JSON.parse(raw) as WorkspaceRecord;
}

/**
 * Store a workspace record in KV.
 */
export async function putWorkspace(
  kv: KVNamespace,
  record: WorkspaceRecord,
): Promise<void> {
  await kv.put(`workspace:${record.workspace_id}`, JSON.stringify(record));
}

/**
 * Encrypt a bot token with nacl.secretbox for storage in KV.
 * Uses the first 32 bytes of the broker's private key as the secretbox key.
 *
 * @returns base64-encoded nonce + ciphertext
 */
export function encryptBotToken(botToken: string, brokerKeyBase64: string): string {
  const key = decodeBase64(brokerKeyBase64).slice(0, nacl.secretbox.keyLength);
  const nonce = nacl.randomBytes(nacl.secretbox.nonceLength);
  const plaintext = new TextEncoder().encode(botToken);
  const ciphertext = nacl.secretbox(plaintext, nonce, key);
  // Output: nonce || ciphertext
  const combined = new Uint8Array(nonce.length + ciphertext.length);
  combined.set(nonce, 0);
  combined.set(ciphertext, nonce.length);
  return encodeBase64(combined);
}

/**
 * Decrypt a bot token from KV storage.
 *
 * @param encrypted - base64-encoded nonce + ciphertext (from encryptBotToken)
 * @param brokerKeyBase64 - the broker's private key (base64)
 * @returns the plaintext bot token
 */
export function decryptBotToken(encrypted: string, brokerKeyBase64: string): string {
  const key = decodeBase64(brokerKeyBase64).slice(0, nacl.secretbox.keyLength);
  const combined = decodeBase64(encrypted);
  const nonce = combined.slice(0, nacl.secretbox.nonceLength);
  const ciphertext = combined.slice(nacl.secretbox.nonceLength);
  const plaintext = nacl.secretbox.open(ciphertext, nonce, key);
  if (!plaintext) {
    throw new Error("decryptBotToken: decryption failed — invalid key or corrupted data");
  }
  return new TextDecoder().decode(plaintext);
}

/**
 * Create a pending workspace record after OAuth.
 * The bot_token is encrypted with nacl.secretbox before storage.
 *
 * @param brokerKeyBase64 - the broker's private key for encrypting the bot token
 */
export async function createPendingWorkspace(
  kv: KVNamespace,
  workspaceId: string,
  teamName: string,
  botToken: string,
  authCodeHash: string,
  brokerKeyBase64: string,
): Promise<WorkspaceRecord> {
  const record: WorkspaceRecord = {
    workspace_id: workspaceId,
    team_name: teamName,
    server_url: "",
    server_pubkey: "",
    server_signing_pubkey: "",
    bot_token: encryptBotToken(botToken, brokerKeyBase64),
    status: "pending",
    updated_at: new Date().toISOString(),
    auth_code_hash: authCodeHash,
  };
  await putWorkspace(kv, record);
  return record;
}

/**
 * Activate a workspace by registering a server.
 *
 * Clears auth_code_hash after activation to prevent auth code reuse.
 * Returns null if the workspace doesn't exist or is already active
 * (active workspaces must be deactivated before re-registering).
 */
export async function activateWorkspace(
  kv: KVNamespace,
  workspaceId: string,
  serverUrl: string,
  serverPubkey: string,
  serverSigningPubkey: string,
): Promise<WorkspaceRecord | null> {
  const record = await getWorkspace(kv, workspaceId);
  if (!record) return null;

  // Reject re-registration of already-active workspaces.
  // The current server must unregister first (DELETE /api/register).
  if (record.status === "active") return null;

  record.server_url = serverUrl;
  record.server_pubkey = serverPubkey;
  record.server_signing_pubkey = serverSigningPubkey;
  record.status = "active";
  record.updated_at = new Date().toISOString();
  // Clear auth_code_hash — one-time use only. Prevents hijacking via code reuse.
  record.auth_code_hash = "";
  await putWorkspace(kv, record);
  return record;
}

/**
 * Deactivate a workspace (unlink server).
 */
export async function deactivateWorkspace(
  kv: KVNamespace,
  workspaceId: string,
): Promise<boolean> {
  const record = await getWorkspace(kv, workspaceId);
  if (!record) return false;

  record.status = "inactive";
  record.server_url = "";
  record.server_pubkey = "";
  record.server_signing_pubkey = "";
  record.updated_at = new Date().toISOString();
  await putWorkspace(kv, record);
  return true;
}

/**
 * Hash an auth code for storage using HMAC-SHA256, keyed with a broker secret.
 * We never store raw auth codes. HMAC prevents offline brute-force without
 * knowledge of the broker's secret key.
 *
 * @param authCode - the raw auth code to hash
 * @param brokerSecret - the broker's private key (used as HMAC key)
 */
export async function hashAuthCode(authCode: string, brokerSecret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(brokerSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(authCode));
  const bytes = new Uint8Array(mac);
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
