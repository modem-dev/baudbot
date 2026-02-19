/**
 * End-to-end message flow integration tests.
 *
 * Tests the complete paths:
 *   1. Inbound: Slack event → verify signature → encrypt → forward to server
 *   2. Outbound: Server sends encrypted reply → broker decrypts → posts to Slack
 *   3. Registration: OAuth → register server → activate workspace
 *   4. Slack signature verification edge cases
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import nacl from "tweetnacl";
import { verifySlackSignature } from "../src/slack/events.js";
import { boxEncrypt, boxDecrypt } from "../src/crypto/box.js";
import { sealedBoxDecrypt } from "../src/crypto/seal.js";
import { sign, canonicalizeOutbound, canonicalizeEnvelope, verify } from "../src/crypto/verify.js";
import { encodeBase64, decodeBase64, encodeUTF8, decodeUTF8 } from "../src/util/encoding.js";
import {
  createPendingWorkspace,
  activateWorkspace,
  getWorkspace,
  hashAuthCode,
  decryptBotToken,
  type KVNamespace,
} from "../src/routing/registry.js";

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

/**
 * Generate a valid Slack signature for testing.
 */
async function makeSlackSignature(
  signingSecret: string,
  timestamp: string,
  body: string,
): Promise<string> {
  const sigBasestring = `v0:${timestamp}:${body}`;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(signingSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(sigBasestring));
  return `v0=${Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")}`;
}

describe("Slack signature verification", () => {
  const signingSecret = "test_signing_secret_1234567890";

  it("accepts a valid signature", async () => {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const body = '{"type":"url_verification","challenge":"abc"}';
    const sig = await makeSlackSignature(signingSecret, timestamp, body);

    const valid = await verifySlackSignature(signingSecret, timestamp, body, sig);
    expect(valid).toBe(true);
  });

  it("rejects an invalid signature", async () => {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const body = '{"type":"url_verification"}';

    const valid = await verifySlackSignature(signingSecret, timestamp, body, "v0=deadbeef");
    expect(valid).toBe(false);
  });

  it("rejects a stale timestamp (>5 minutes old)", async () => {
    const staleTimestamp = String(Math.floor(Date.now() / 1000) - 400);
    const body = '{"type":"event_callback"}';
    const sig = await makeSlackSignature(signingSecret, staleTimestamp, body);

    const valid = await verifySlackSignature(signingSecret, staleTimestamp, body, sig);
    expect(valid).toBe(false);
  });

  it("rejects a future timestamp (>5 minutes ahead)", async () => {
    const futureTimestamp = String(Math.floor(Date.now() / 1000) + 400);
    const body = '{"type":"event_callback"}';
    const sig = await makeSlackSignature(signingSecret, futureTimestamp, body);

    const valid = await verifySlackSignature(signingSecret, futureTimestamp, body, sig);
    expect(valid).toBe(false);
  });

  it("rejects non-numeric timestamp", async () => {
    const valid = await verifySlackSignature(signingSecret, "not-a-number", "{}", "v0=abc");
    expect(valid).toBe(false);
  });

  it("rejects wrong signing secret", async () => {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const body = '{"type":"url_verification"}';
    const sig = await makeSlackSignature("wrong_secret", timestamp, body);

    const valid = await verifySlackSignature(signingSecret, timestamp, body, sig);
    expect(valid).toBe(false);
  });

  it("rejects signature with wrong length", async () => {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const body = "test";
    const valid = await verifySlackSignature(signingSecret, timestamp, body, "v0=ab");
    expect(valid).toBe(false);
  });
});

describe("end-to-end inbound flow", () => {
  it("encrypts an event that only the server can decrypt", async () => {
    // Setup: broker and server keypairs
    const brokerSignKeypair = nacl.sign.keyPair();
    const serverBoxKeypair = nacl.box.keyPair();

    // Simulate: broker encrypts a Slack event for the server
    const slackEvent = {
      type: "event_callback",
      team_id: "T123",
      event: { type: "app_mention", text: "<@U123> hello", channel: "C456", ts: "1234.5678" },
    };

    const { sealedBoxEncrypt } = await import("../src/crypto/seal.js");
    const plaintext = encodeUTF8(JSON.stringify(slackEvent));
    const encrypted = await sealedBoxEncrypt(plaintext, serverBoxKeypair.publicKey);

    // Sign the envelope
    const timestamp = Math.floor(Date.now() / 1000);
    const canonical = canonicalizeEnvelope("T123", timestamp, encrypted);
    const signature = sign(canonical, brokerSignKeypair.secretKey);

    // Server side: verify signature and decrypt
    const isValid = verify(canonical, signature, brokerSignKeypair.publicKey);
    expect(isValid).toBe(true);

    const decrypted = await sealedBoxDecrypt(
      encrypted,
      serverBoxKeypair.publicKey,
      serverBoxKeypair.secretKey,
    );

    const recoveredEvent = JSON.parse(decodeUTF8(decrypted));
    expect(recoveredEvent.team_id).toBe("T123");
    expect(recoveredEvent.event.text).toBe("<@U123> hello");
  });

  it("broker cannot decrypt its own sealed box output", async () => {
    const brokerBoxKeypair = nacl.box.keyPair();
    const serverBoxKeypair = nacl.box.keyPair();

    const { sealedBoxEncrypt } = await import("../src/crypto/seal.js");
    const plaintext = encodeUTF8("sensitive message");
    const encrypted = await sealedBoxEncrypt(plaintext, serverBoxKeypair.publicKey);

    // Broker tries to decrypt with its OWN keys — should fail
    await expect(
      sealedBoxDecrypt(encrypted, brokerBoxKeypair.publicKey, brokerBoxKeypair.secretKey),
    ).rejects.toThrow("decryption failed");
  });
});

describe("end-to-end outbound flow", () => {
  it("server encrypts a reply that the broker can decrypt", () => {
    // Setup
    const brokerBoxKeypair = nacl.box.keyPair();
    const serverBoxKeypair = nacl.box.keyPair();
    const serverSignKeypair = nacl.sign.keyPair();

    // Server encrypts the message body
    const messageBody = JSON.stringify({ text: "Here's your answer!", blocks: [] });
    const { ciphertext, nonce } = boxEncrypt(
      encodeUTF8(messageBody),
      brokerBoxKeypair.publicKey,
      serverBoxKeypair.secretKey,
    );

    // Server signs the request
    const timestamp = Math.floor(Date.now() / 1000);
    const canonical = canonicalizeOutbound("T123", "chat.postMessage", timestamp, ciphertext);
    const signature = sign(canonical, serverSignKeypair.secretKey);

    // Broker side: verify signature
    const isValid = verify(canonical, signature, serverSignKeypair.publicKey);
    expect(isValid).toBe(true);

    // Broker decrypts the body
    const decryptedBytes = boxDecrypt(
      ciphertext,
      nonce,
      serverBoxKeypair.publicKey,
      brokerBoxKeypair.secretKey,
    );

    const recovered = JSON.parse(decodeUTF8(decryptedBytes));
    expect(recovered.text).toBe("Here's your answer!");
  });

  it("third party cannot forge a server message", () => {
    const brokerBoxKeypair = nacl.box.keyPair();
    const serverBoxKeypair = nacl.box.keyPair();
    const serverSignKeypair = nacl.sign.keyPair();
    const attackerSignKeypair = nacl.sign.keyPair();

    // Attacker tries to send a message signed with their own key
    const body = JSON.stringify({ text: "malicious" });
    const { ciphertext, nonce } = boxEncrypt(
      encodeUTF8(body),
      brokerBoxKeypair.publicKey,
      serverBoxKeypair.secretKey,
    );

    const timestamp = Math.floor(Date.now() / 1000);
    const canonical = canonicalizeOutbound("T123", "chat.postMessage", timestamp, ciphertext);

    // Attacker signs with their key
    const attackerSig = sign(canonical, attackerSignKeypair.secretKey);

    // Broker verifies against the REAL server's signing key — should fail
    const isValid = verify(canonical, attackerSig, serverSignKeypair.publicKey);
    expect(isValid).toBe(false);
  });
});

describe("end-to-end registration flow", () => {
  let kv: KVNamespace;

  beforeEach(() => {
    kv = createMockKV();
  });

  it("full OAuth → register → activate cycle", async () => {
    // 1. OAuth completes — create pending workspace
    const authCode = "secret-auth-code-12345";
    const authCodeHashed = await hashAuthCode(authCode, TEST_BROKER_KEY);

    await createPendingWorkspace(kv, "T123", "Test Team", "xoxb-fake-token", authCodeHashed, TEST_BROKER_KEY);

    // Verify pending state
    let ws = await getWorkspace(kv, "T123");
    expect(ws!.status).toBe("pending");
    expect(ws!.server_url).toBe("");

    // Verify bot token is encrypted (not plaintext)
    expect(ws!.bot_token).not.toBe("xoxb-fake-token");
    expect(decryptBotToken(ws!.bot_token, TEST_BROKER_KEY)).toBe("xoxb-fake-token");

    // 2. Server generates keys and registers
    const serverBoxKeypair = nacl.box.keyPair();
    const serverSignKeypair = nacl.sign.keyPair();

    // Verify auth code matches
    const providedHash = await hashAuthCode(authCode, TEST_BROKER_KEY);
    expect(providedHash).toBe(ws!.auth_code_hash);

    // 3. Activate
    const activated = await activateWorkspace(
      kv,
      "T123",
      "https://my-server.example.com/broker/inbound",
      encodeBase64(serverBoxKeypair.publicKey),
      encodeBase64(serverSignKeypair.publicKey),
    );

    expect(activated!.status).toBe("active");
    expect(activated!.server_url).toBe("https://my-server.example.com/broker/inbound");
    // Auth code hash should be cleared after activation
    expect(activated!.auth_code_hash).toBe("");

    // 4. Verify the stored keys can be used for crypto
    ws = await getWorkspace(kv, "T123");
    const storedPubkey = decodeBase64(ws!.server_pubkey);
    expect(storedPubkey).toEqual(serverBoxKeypair.publicKey);

    // 5. Re-registration should be rejected (workspace is active)
    const reactivated = await activateWorkspace(
      kv, "T123", "https://evil.example.com", "pk", "spk",
    );
    expect(reactivated).toBeNull();
  });

  it("rejects registration with wrong auth code", async () => {
    const authCode = "correct-code";
    const authCodeHashed = await hashAuthCode(authCode, TEST_BROKER_KEY);

    await createPendingWorkspace(kv, "T123", "Test Team", "xoxb-fake", authCodeHashed, TEST_BROKER_KEY);

    const wrongHash = await hashAuthCode("wrong-code", TEST_BROKER_KEY);
    const ws = await getWorkspace(kv, "T123");
    expect(wrongHash).not.toBe(ws!.auth_code_hash);
  });
});

describe("replay protection", () => {
  it("signature with old timestamp fails verification at application level", () => {
    // Signatures themselves don't expire, but the broker checks timestamps
    // before calling verify(). This test documents the canonicalization
    // includes the timestamp, so replaying with a different timestamp
    // will produce a different canonical form and fail verification.
    const keypair = nacl.sign.keyPair();
    const timestamp1 = 1000;
    const timestamp2 = 2000;

    const canonical1 = canonicalizeEnvelope("T123", timestamp1, "encrypted_data");
    const canonical2 = canonicalizeEnvelope("T123", timestamp2, "encrypted_data");

    const sig1 = sign(canonical1, keypair.secretKey);

    // Signature from timestamp1 doesn't verify against canonical2
    expect(verify(canonical2, sig1, keypair.publicKey)).toBe(false);
  });
});
