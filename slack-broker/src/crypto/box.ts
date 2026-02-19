/**
 * Authenticated encryption — used for outbound (server → Slack) path.
 *
 * The server encrypts the message body with crypto_box (server_sk, broker_pk).
 * The broker decrypts transiently to post to Slack, then zeroes the plaintext.
 *
 * crypto_box provides:
 *   - Confidentiality (XSalsa20)
 *   - Integrity (Poly1305 MAC)
 *   - Authentication (sender identity verified via shared secret)
 */

import nacl from "tweetnacl";
import { decodeBase64, encodeBase64 } from "../util/encoding.js";

/**
 * Encrypt with crypto_box (authenticated encryption).
 *
 * Used by the SERVER to encrypt outbound message bodies.
 * Included here for testing and symmetry.
 *
 * @returns { ciphertext: base64, nonce: base64 }
 */
export function boxEncrypt(
  plaintext: Uint8Array,
  recipientPublicKey: Uint8Array,
  senderSecretKey: Uint8Array,
): { ciphertext: string; nonce: string } {
  const nonce = nacl.randomBytes(nacl.box.nonceLength);
  const ciphertext = nacl.box(plaintext, nonce, recipientPublicKey, senderSecretKey);

  if (!ciphertext) {
    throw new Error("boxEncrypt: encryption failed");
  }

  return {
    ciphertext: encodeBase64(ciphertext),
    nonce: encodeBase64(nonce),
  };
}

/**
 * Decrypt with crypto_box_open (authenticated decryption).
 *
 * Used by the BROKER to decrypt outbound message bodies from servers.
 * The broker decrypts, posts to Slack, then callers must zero the result.
 *
 * @param ciphertextBase64 - base64-encoded ciphertext
 * @param nonceBase64 - base64-encoded nonce
 * @param senderPublicKey - the server's public key (authenticates sender)
 * @param recipientSecretKey - the broker's secret key
 * @returns decrypted plaintext bytes
 */
export function boxDecrypt(
  ciphertextBase64: string,
  nonceBase64: string,
  senderPublicKey: Uint8Array,
  recipientSecretKey: Uint8Array,
): Uint8Array {
  const ciphertext = decodeBase64(ciphertextBase64);
  const nonce = decodeBase64(nonceBase64);

  if (nonce.length !== nacl.box.nonceLength) {
    throw new Error(`boxDecrypt: invalid nonce length (expected ${nacl.box.nonceLength}, got ${nonce.length})`);
  }

  const plaintext = nacl.box.open(ciphertext, nonce, senderPublicKey, recipientSecretKey);

  if (!plaintext) {
    throw new Error("boxDecrypt: decryption failed — invalid key, corrupted data, or wrong sender");
  }

  return plaintext;
}

/**
 * Zero out a Uint8Array to minimize plaintext residence in memory.
 * Call this after posting the decrypted content to Slack.
 */
export function zeroBytes(arr: Uint8Array): void {
  arr.fill(0);
}
