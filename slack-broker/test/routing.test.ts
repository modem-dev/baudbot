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
  type WorkspaceRecord,
  type KVNamespace,
} from "../src/routing/registry.js";
import { forwardEvent, type ForwardResult } from "../src/routing/forward.js";
import nacl from "tweetnacl";
import { encodeBase64 } from "../src/util/encoding.js";

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

  it("creates a pending workspace", async () => {
    const record = await createPendingWorkspace(kv, "T123", "Test Team", "xoxb-token", "hash123");

    expect(record.workspace_id).toBe("T123");
    expect(record.team_name).toBe("Test Team");
    expect(record.bot_token).toBe("xoxb-token");
    expect(record.status).toBe("pending");
    expect(record.auth_code_hash).toBe("hash123");
    expect(record.server_url).toBe("");
    expect(record.server_pubkey).toBe("");

    // Verify it's stored in KV
    const fetched = await getWorkspace(kv, "T123");
    expect(fetched).toEqual(record);
  });

  it("activates a workspace with server details", async () => {
    await createPendingWorkspace(kv, "T123", "Test Team", "xoxb-token", "hash123");

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
  });

  it("returns null when activating non-existent workspace", async () => {
    const result = await activateWorkspace(kv, "T_NONE", "url", "pk", "spk");
    expect(result).toBeNull();
  });

  it("deactivates a workspace", async () => {
    await createPendingWorkspace(kv, "T123", "Test Team", "xoxb-token", "hash123");
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

describe("hashAuthCode", () => {
  it("produces a hex string", async () => {
    const hash = await hashAuthCode("test-code");
    expect(hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("is deterministic", async () => {
    const h1 = await hashAuthCode("same-code");
    const h2 = await hashAuthCode("same-code");
    expect(h1).toBe(h2);
  });

  it("differs for different inputs", async () => {
    const h1 = await hashAuthCode("code-a");
    const h2 = await hashAuthCode("code-b");
    expect(h1).not.toBe(h2);
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
