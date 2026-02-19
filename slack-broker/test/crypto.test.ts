/**
 * Unit tests for crypto modules: sealed boxes, authenticated encryption, signatures.
 */

import { describe, it, expect } from "vitest";
import nacl from "tweetnacl";
import { sealedBoxEncrypt, sealedBoxDecrypt } from "../src/crypto/seal.js";
import { boxEncrypt, boxDecrypt, zeroBytes } from "../src/crypto/box.js";
import {
  sign,
  verify,
  generateSigningKeypair,
  canonicalizeEnvelope,
  canonicalizeOutbound,
} from "../src/crypto/verify.js";
import { encodeBase64, decodeBase64, encodeUTF8, decodeUTF8 } from "../src/util/encoding.js";

describe("sealed box (crypto_box_seal)", () => {
  it("encrypts and decrypts a message", async () => {
    const recipientKeypair = nacl.box.keyPair();
    const plaintext = encodeUTF8("hello from Slack");

    const sealed = await sealedBoxEncrypt(plaintext, recipientKeypair.publicKey);
    expect(sealed).toBeTruthy();
    expect(typeof sealed).toBe("string");

    const decrypted = await sealedBoxDecrypt(
      sealed,
      recipientKeypair.publicKey,
      recipientKeypair.secretKey,
    );
    expect(decodeUTF8(decrypted)).toBe("hello from Slack");
  });

  it("different encryptions produce different ciphertexts (ephemeral keys)", async () => {
    const recipientKeypair = nacl.box.keyPair();
    const plaintext = encodeUTF8("same message");

    const sealed1 = await sealedBoxEncrypt(plaintext, recipientKeypair.publicKey);
    const sealed2 = await sealedBoxEncrypt(plaintext, recipientKeypair.publicKey);

    // Ephemeral keypairs mean different ciphertexts
    expect(sealed1).not.toBe(sealed2);

    // Both decrypt to the same plaintext
    const d1 = await sealedBoxDecrypt(sealed1, recipientKeypair.publicKey, recipientKeypair.secretKey);
    const d2 = await sealedBoxDecrypt(sealed2, recipientKeypair.publicKey, recipientKeypair.secretKey);
    expect(decodeUTF8(d1)).toBe("same message");
    expect(decodeUTF8(d2)).toBe("same message");
  });

  it("fails to decrypt with wrong private key", async () => {
    const recipientKeypair = nacl.box.keyPair();
    const wrongKeypair = nacl.box.keyPair();
    const plaintext = encodeUTF8("secret message");

    const sealed = await sealedBoxEncrypt(plaintext, recipientKeypair.publicKey);

    await expect(
      sealedBoxDecrypt(sealed, wrongKeypair.publicKey, wrongKeypair.secretKey),
    ).rejects.toThrow("decryption failed");
  });

  it("fails on truncated ciphertext", async () => {
    const recipientKeypair = nacl.box.keyPair();

    await expect(
      sealedBoxDecrypt("AAAA", recipientKeypair.publicKey, recipientKeypair.secretKey),
    ).rejects.toThrow("ciphertext too short");
  });

  it("handles empty plaintext", async () => {
    const recipientKeypair = nacl.box.keyPair();
    const plaintext = new Uint8Array(0);

    const sealed = await sealedBoxEncrypt(plaintext, recipientKeypair.publicKey);
    const decrypted = await sealedBoxDecrypt(
      sealed,
      recipientKeypair.publicKey,
      recipientKeypair.secretKey,
    );
    expect(decrypted.length).toBe(0);
  });

  it("handles large payloads", async () => {
    const recipientKeypair = nacl.box.keyPair();
    const plaintext = new Uint8Array(100_000);
    // Fill in chunks — crypto.getRandomValues has a 65536-byte limit
    for (let i = 0; i < plaintext.length; i += 65536) {
      const chunk = plaintext.subarray(i, Math.min(i + 65536, plaintext.length));
      crypto.getRandomValues(chunk);
    }

    const sealed = await sealedBoxEncrypt(plaintext, recipientKeypair.publicKey);
    const decrypted = await sealedBoxDecrypt(
      sealed,
      recipientKeypair.publicKey,
      recipientKeypair.secretKey,
    );
    expect(decrypted).toEqual(plaintext);
  });
});

describe("authenticated box (crypto_box)", () => {
  it("encrypts and decrypts a message", () => {
    const sender = nacl.box.keyPair();
    const recipient = nacl.box.keyPair();
    const plaintext = encodeUTF8('{"text": "hello"}');

    const { ciphertext, nonce } = boxEncrypt(plaintext, recipient.publicKey, sender.secretKey);
    expect(ciphertext).toBeTruthy();
    expect(nonce).toBeTruthy();

    const decrypted = boxDecrypt(ciphertext, nonce, sender.publicKey, recipient.secretKey);
    expect(decodeUTF8(decrypted)).toBe('{"text": "hello"}');
  });

  it("verifies sender identity (fails with wrong sender key)", () => {
    const sender = nacl.box.keyPair();
    const recipient = nacl.box.keyPair();
    const imposter = nacl.box.keyPair();
    const plaintext = encodeUTF8("authentic message");

    const { ciphertext, nonce } = boxEncrypt(plaintext, recipient.publicKey, sender.secretKey);

    // Try to decrypt claiming a different sender
    expect(() =>
      boxDecrypt(ciphertext, nonce, imposter.publicKey, recipient.secretKey),
    ).toThrow("decryption failed");
  });

  it("fails with wrong recipient key", () => {
    const sender = nacl.box.keyPair();
    const recipient = nacl.box.keyPair();
    const wrongRecipient = nacl.box.keyPair();
    const plaintext = encodeUTF8("secret");

    const { ciphertext, nonce } = boxEncrypt(plaintext, recipient.publicKey, sender.secretKey);

    expect(() =>
      boxDecrypt(ciphertext, nonce, sender.publicKey, wrongRecipient.secretKey),
    ).toThrow("decryption failed");
  });

  it("fails with invalid nonce length", () => {
    const sender = nacl.box.keyPair();
    const recipient = nacl.box.keyPair();
    const plaintext = encodeUTF8("test");

    const { ciphertext } = boxEncrypt(plaintext, recipient.publicKey, sender.secretKey);
    const badNonce = encodeBase64(new Uint8Array(8)); // Wrong length

    expect(() =>
      boxDecrypt(ciphertext, badNonce, sender.publicKey, recipient.secretKey),
    ).toThrow("invalid nonce length");
  });

  it("each encryption uses a unique nonce", () => {
    const sender = nacl.box.keyPair();
    const recipient = nacl.box.keyPair();
    const plaintext = encodeUTF8("same");

    const r1 = boxEncrypt(plaintext, recipient.publicKey, sender.secretKey);
    const r2 = boxEncrypt(plaintext, recipient.publicKey, sender.secretKey);

    expect(r1.nonce).not.toBe(r2.nonce);
    expect(r1.ciphertext).not.toBe(r2.ciphertext);
  });
});

describe("zeroBytes", () => {
  it("zeroes a buffer", () => {
    const buf = new Uint8Array([1, 2, 3, 4, 5]);
    zeroBytes(buf);
    expect(buf).toEqual(new Uint8Array([0, 0, 0, 0, 0]));
  });
});

describe("signatures (Ed25519)", () => {
  it("sign and verify round-trip", () => {
    const keypair = generateSigningKeypair();
    const message = encodeUTF8("important envelope");

    const sig = sign(message, keypair.secretKey);
    expect(verify(message, sig, keypair.publicKey)).toBe(true);
  });

  it("rejects tampered message", () => {
    const keypair = generateSigningKeypair();
    const message = encodeUTF8("original");

    const sig = sign(message, keypair.secretKey);
    const tampered = encodeUTF8("tampered");
    expect(verify(tampered, sig, keypair.publicKey)).toBe(false);
  });

  it("rejects wrong public key", () => {
    const keypair1 = generateSigningKeypair();
    const keypair2 = generateSigningKeypair();
    const message = encodeUTF8("test");

    const sig = sign(message, keypair1.secretKey);
    expect(verify(message, sig, keypair2.publicKey)).toBe(false);
  });

  it("rejects invalid signature format", () => {
    const keypair = generateSigningKeypair();
    const message = encodeUTF8("test");

    expect(verify(message, "not-valid-base64!!!", keypair.publicKey)).toBe(false);
  });

  it("rejects truncated signature", () => {
    const keypair = generateSigningKeypair();
    const message = encodeUTF8("test");

    const sig = sign(message, keypair.secretKey);
    const truncated = sig.slice(0, 10);
    expect(verify(message, truncated, keypair.publicKey)).toBe(false);
  });
});

describe("canonicalize", () => {
  it("envelope canonicalization is deterministic", () => {
    const a = canonicalizeEnvelope("T123", 1000, "encrypted_data");
    const b = canonicalizeEnvelope("T123", 1000, "encrypted_data");
    expect(a).toEqual(b);
  });

  it("envelope canonicalization differs with different inputs", () => {
    const a = canonicalizeEnvelope("T123", 1000, "data1");
    const b = canonicalizeEnvelope("T123", 1000, "data2");
    expect(a).not.toEqual(b);
  });

  it("outbound canonicalization is deterministic", () => {
    const a = canonicalizeOutbound("T123", "chat.postMessage", 1000, "body");
    const b = canonicalizeOutbound("T123", "chat.postMessage", 1000, "body");
    expect(a).toEqual(b);
  });

  it("outbound canonicalization includes action", () => {
    const a = canonicalizeOutbound("T123", "chat.postMessage", 1000, "body");
    const b = canonicalizeOutbound("T123", "reactions.add", 1000, "body");
    expect(a).not.toEqual(b);
  });
});

describe("encoding utilities", () => {
  it("base64 round-trip", () => {
    const original = new Uint8Array([0, 1, 127, 128, 255]);
    const encoded = encodeBase64(original);
    const decoded = decodeBase64(encoded);
    expect(decoded).toEqual(original);
  });

  it("utf8 round-trip", () => {
    const original = "Hello 🌍 world — test";
    const encoded = encodeUTF8(original);
    const decoded = decodeUTF8(encoded);
    expect(decoded).toBe(original);
  });

  it("base64 of empty array", () => {
    const encoded = encodeBase64(new Uint8Array(0));
    const decoded = decodeBase64(encoded);
    expect(decoded.length).toBe(0);
  });
});
