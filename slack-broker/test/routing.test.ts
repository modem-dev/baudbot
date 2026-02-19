/**
 * Unit tests for registry (KV-backed workspace routing) and forwarding logic.
 */

import { describe, it, expect, beforeEach, vi } from "vitest";
import {
  getWorkspace,
  putWorkspace,
  createPendingWorkspace,
  activateWorkspace,
  deactivateWorkspace,
  hashAuthCode,
  encryptBotToken,
  decryptBotToken,
  type WorkspaceRecord,
  type KVNamespace,
} from "../src/routing/registry.js";
import { forwardEvent, type ForwardResult } from "../src/routing/forward.js";
import nacl from "tweetnacl";
import { encodeBase64 } from "../src/util/encoding.js";

/** Test broker key (base64-encoded 32-byte key). */
const TEST_BROKER_KEY = encodeBase64(nacl.randomBytes(32));

/** In-memory KV mock. */
function createMockKV(): KVNamespace {
  const store = new Map<string, string>();
  return {
    async get(key: string) {
      return store.get(key) ?? null;
    },
    async put(key: string, value: string) {
      store.set(key, value);
    },
    async delete(key: string) {
      store.delete(key);
    },
  };
}

describe("registry", () => {
  let kv: KVNamespace;

  beforeEach(() => {
    kv = createMockKV();
  });

  it("returns null for unknown workspace", async () => {
    const result = await getWorkspace(kv, "T_UNKNOWN");
    expect(result).toBeNull();
  });

  it("creates a pending workspace with encrypted bot token", async () => {
    const record = await createPendingWorkspace(kv, "T123", "Test Team", "xoxb-token", "hash123", TEST_BROKER_KEY);

    expect(record.workspace_id).toBe("T123");
    expect(record.team_name).toBe("Test Team");
    // bot_token is now encrypted — should NOT be plaintext
    expect(record.bot_token).not.toBe("xoxb-token");
    // Decrypting should yield the original
    expect(decryptBotToken(record.bot_token, TEST_BROKER_KEY)).toBe("xoxb-token");
    expect(record.status).toBe("pending");
    expect(record.auth_code_hash).toBe("hash123");
    expect(record.server_url).toBe("");
    expect(record.server_pubkey).toBe("");

    // Verify it's stored in KV
    const fetched = await getWorkspace(kv, "T123");
    expect(fetched).toEqual(record);
  });

  it("activates a workspace with server details and clears auth_code_hash", async () => {
    await createPendingWorkspace(kv, "T123", "Test Team", "xoxb-token", "hash123", TEST_BROKER_KEY);

    const activated = await activateWorkspace(
      kv,
      "T123",
      "https://server.example.com/broker/inbound",
      "server_pubkey_base64",
      "server_signing_pubkey_base64",
    );

    expect(activated).not.toBeNull();
    expect(activated!.status).toBe("active");
    expect(activated!.server_url).toBe("https://server.example.com/broker/inbound");
    expect(activated!.server_pubkey).toBe("server_pubkey_base64");
    expect(activated!.server_signing_pubkey).toBe("server_signing_pubkey_base64");
    // Auth code hash should be cleared after activation
    expect(activated!.auth_code_hash).toBe("");
  });

  it("rejects activation of already-active workspace", async () => {
    await createPendingWorkspace(kv, "T123", "Test Team", "xoxb-token", "hash123", TEST_BROKER_KEY);
    await activateWorkspace(kv, "T123", "https://server1.example.com", "pk1", "spk1");

    // Second activation should fail
    const result = await activateWorkspace(kv, "T123", "https://server2.example.com", "pk2", "spk2");
    expect(result).toBeNull();

    // Original server should still be registered
    const ws = await getWorkspace(kv, "T123");
    expect(ws!.server_url).toBe("https://server1.example.com");
  });

  it("returns null when activating non-existent workspace", async () => {
    const result = await activateWorkspace(kv, "T_NONE", "url", "pk", "spk");
    expect(result).toBeNull();
  });

  it("deactivates a workspace", async () => {
    await createPendingWorkspace(kv, "T123", "Test Team", "xoxb-token", "hash123", TEST_BROKER_KEY);
    await activateWorkspace(kv, "T123", "https://server.example.com", "pk", "spk");

    const result = await deactivateWorkspace(kv, "T123");
    expect(result).toBe(true);

    const workspace = await getWorkspace(kv, "T123");
    expect(workspace!.status).toBe("inactive");
    expect(workspace!.server_url).toBe("");
    expect(workspace!.server_pubkey).toBe("");
  });

  it("returns false when deactivating non-existent workspace", async () => {
    const result = await deactivateWorkspace(kv, "T_NONE");
    expect(result).toBe(false);
  });

  it("put and get workspace round-trip", async () => {
    const record: WorkspaceRecord = {
      workspace_id: "T999",
      team_name: "Round Trip",
      server_url: "https://example.com",
      server_pubkey: "pk",
      server_signing_pubkey: "spk",
      bot_token: "xoxb-test",
      status: "active",
      updated_at: new Date().toISOString(),
      auth_code_hash: "abc",
    };

    await putWorkspace(kv, record);
    const fetched = await getWorkspace(kv, "T999");
    expect(fetched).toEqual(record);
  });
});

describe("hashAuthCode (HMAC-SHA256)", () => {
  it("produces a hex string", async () => {
    const hash = await hashAuthCode("test-code", "broker-secret");
    expect(hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("is deterministic", async () => {
    const h1 = await hashAuthCode("same-code", "broker-secret");
    const h2 = await hashAuthCode("same-code", "broker-secret");
    expect(h1).toBe(h2);
  });

  it("differs for different inputs", async () => {
    const h1 = await hashAuthCode("code-a", "broker-secret");
    const h2 = await hashAuthCode("code-b", "broker-secret");
    expect(h1).not.toBe(h2);
  });

  it("differs for different secrets (keyed)", async () => {
    const h1 = await hashAuthCode("same-code", "secret-1");
    const h2 = await hashAuthCode("same-code", "secret-2");
    expect(h1).not.toBe(h2);
  });
});

describe("workspace_id validation", () => {
  it("accepts valid Slack team IDs", () => {
    expect(/^T[A-Z0-9]+$/.test("T09192W1Z34")).toBe(true);
    expect(/^T[A-Z0-9]+$/.test("T123")).toBe(true);
    expect(/^T[A-Z0-9]+$/.test("TABCDEF012")).toBe(true);
  });

  it("rejects IDs with pipe delimiter (injection)", () => {
    expect(/^T[A-Z0-9]+$/.test("T123|evil")).toBe(false);
  });

  it("rejects IDs that don't start with T", () => {
    expect(/^T[A-Z0-9]+$/.test("U123")).toBe(false);
    expect(/^T[A-Z0-9]+$/.test("123")).toBe(false);
  });

  it("rejects empty or T-only IDs", () => {
    expect(/^T[A-Z0-9]+$/.test("")).toBe(false);
    expect(/^T[A-Z0-9]+$/.test("T")).toBe(false);
  });
});

describe("bot token encryption", () => {
  it("encrypts and decrypts a bot token", () => {
    const token = "xoxb-1234567890-abcdefghij";
    const encrypted = encryptBotToken(token, TEST_BROKER_KEY);
    expect(encrypted).not.toBe(token);
    expect(decryptBotToken(encrypted, TEST_BROKER_KEY)).toBe(token);
  });

  it("different encryptions produce different ciphertexts (random nonce)", () => {
    const token = "xoxb-same-token";
    const e1 = encryptBotToken(token, TEST_BROKER_KEY);
    const e2 = encryptBotToken(token, TEST_BROKER_KEY);
    expect(e1).not.toBe(e2);
    // Both decrypt to the same value
    expect(decryptBotToken(e1, TEST_BROKER_KEY)).toBe(token);
    expect(decryptBotToken(e2, TEST_BROKER_KEY)).toBe(token);
  });

  it("fails to decrypt with wrong key", () => {
    const token = "xoxb-secret";
    const wrongKey = encodeBase64(nacl.randomBytes(32));
    const encrypted = encryptBotToken(token, TEST_BROKER_KEY);
    expect(() => decryptBotToken(encrypted, wrongKey)).toThrow("decryption failed");
  });
});

describe("forwardEvent", () => {
  const brokerSignKeypair = nacl.sign.keyPair();

  function makeActiveWorkspace(overrides?: Partial<WorkspaceRecord>): WorkspaceRecord {
    const serverKeypair = nacl.box.keyPair();
    return {
      workspace_id: "T123",
      team_name: "Test",
      server_url: "https://server.example.com/broker/inbound",
      server_pubkey: encodeBase64(serverKeypair.publicKey),
      server_signing_pubkey: "",
      bot_token: "xoxb-test",
      status: "active",
      updated_at: new Date().toISOString(),
      auth_code_hash: "hash",
      ...overrides,
    };
  }

  it("rejects forwarding to non-active workspace", async () => {
    const workspace = makeActiveWorkspace({ status: "pending" });
    const result = await forwardEvent({}, workspace, brokerSignKeypair.secretKey);
    expect(result.ok).toBe(false);
    expect(result.error).toContain("not active");
  });

  it("rejects workspace with missing server_url", async () => {
    const workspace = makeActiveWorkspace({ server_url: "" });
    const result = await forwardEvent({}, workspace, brokerSignKeypair.secretKey);
    expect(result.ok).toBe(false);
    expect(result.error).toContain("missing server configuration");
  });

  it("rejects workspace with missing server_pubkey", async () => {
    const workspace = makeActiveWorkspace({ server_pubkey: "" });
    const result = await forwardEvent({}, workspace, brokerSignKeypair.secretKey);
    expect(result.ok).toBe(false);
    expect(result.error).toContain("missing server configuration");
  });

  it("rejects non-HTTPS server URL", async () => {
    const workspace = makeActiveWorkspace({ server_url: "http://server.example.com/inbound" });
    const result = await forwardEvent({}, workspace, brokerSignKeypair.secretKey);
    expect(result.ok).toBe(false);
    expect(result.error).toContain("HTTPS");
  });

  it("forwards an event to a server (mocked fetch)", async () => {
    const workspace = makeActiveWorkspace();
    const event = { type: "event_callback", event: { type: "message", text: "hi" } };

    // Mock global fetch
    const fetchSpy = vi.fn().mockResolvedValue(new Response("ok", { status: 200 }));
    const originalFetch = globalThis.fetch;
    globalThis.fetch = fetchSpy;

    try {
      const result = await forwardEvent(event, workspace, brokerSignKeypair.secretKey);
      expect(result.ok).toBe(true);
      expect(result.status).toBe(200);

      // Verify fetch was called with the right URL
      expect(fetchSpy).toHaveBeenCalledTimes(1);
      const [url, options] = fetchSpy.mock.calls[0]!;
      expect(url).toBe(workspace.server_url);
      expect(options.method).toBe("POST");

      // Verify envelope structure
      const body = JSON.parse(options.body);
      expect(body.workspace_id).toBe("T123");
      expect(body.encrypted).toBeTruthy();
      expect(body.timestamp).toBeTypeOf("number");
      expect(body.signature).toBeTruthy();

      // Verify headers
      expect(options.headers["Content-Type"]).toBe("application/json");
      expect(options.headers["X-Broker-Signature"]).toBeTruthy();
      expect(options.headers["X-Broker-Timestamp"]).toBeTruthy();
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("reports server error status", async () => {
    const workspace = makeActiveWorkspace();

    const fetchSpy = vi.fn().mockResolvedValue(new Response("bad", { status: 503 }));
    const originalFetch = globalThis.fetch;
    globalThis.fetch = fetchSpy;

    try {
      const result = await forwardEvent({}, workspace, brokerSignKeypair.secretKey);
      expect(result.ok).toBe(false);
      expect(result.status).toBe(503);
      expect(result.error).toContain("503");
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("handles network errors gracefully", async () => {
    const workspace = makeActiveWorkspace();

    const fetchSpy = vi.fn().mockRejectedValue(new Error("connection refused"));
    const originalFetch = globalThis.fetch;
    globalThis.fetch = fetchSpy;

    try {
      const result = await forwardEvent({}, workspace, brokerSignKeypair.secretKey);
      expect(result.ok).toBe(false);
      expect(result.error).toContain("connection refused");
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
