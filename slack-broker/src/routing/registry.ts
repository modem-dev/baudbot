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

import { encodeBase64 } from "../util/encoding.js";

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
 * Create a pending workspace record after OAuth.
 * The bot_token is stored as-is (Cloudflare KV is encrypted at rest).
 */
export async function createPendingWorkspace(
  kv: KVNamespace,
  workspaceId: string,
  teamName: string,
  botToken: string,
  authCodeHash: string,
): Promise<WorkspaceRecord> {
  const record: WorkspaceRecord = {
    workspace_id: workspaceId,
    team_name: teamName,
    server_url: "",
    server_pubkey: "",
    server_signing_pubkey: "",
    bot_token: botToken,
    status: "pending",
    updated_at: new Date().toISOString(),
    auth_code_hash: authCodeHash,
  };
  await putWorkspace(kv, record);
  return record;
}

/**
 * Activate a workspace by registering a server.
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

  record.server_url = serverUrl;
  record.server_pubkey = serverPubkey;
  record.server_signing_pubkey = serverSigningPubkey;
  record.status = "active";
  record.updated_at = new Date().toISOString();
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
 * Hash an auth code for storage (SHA-256, hex-encoded).
 * We never store raw auth codes.
 */
export async function hashAuthCode(authCode: string): Promise<string> {
  const encoded = new TextEncoder().encode(authCode);
  const hash = await crypto.subtle.digest("SHA-256", encoded);
  const bytes = new Uint8Array(hash);
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
