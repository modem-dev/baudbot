/**
 * Sealed box encryption — used for inbound (Slack → server) path.
 *
 * The broker encrypts with the server's public key. Only the server's
 * private key can decrypt. The broker CANNOT decrypt sealed boxes.
 *
 * Uses tweetnacl's box.keyPair + secretbox under the hood to implement
 * the libsodium crypto_box_seal pattern:
 *   1. Generate an ephemeral X25519 keypair
 *   2. Compute shared secret: ECDH(ephemeral_sk, recipient_pk)
 *   3. Derive nonce from ephemeral_pk + recipient_pk
 *   4. Encrypt payload with crypto_box using the shared secret
 *   5. Output: ephemeral_pk || ciphertext
 */

import nacl from "tweetnacl";
import { decodeBase64, encodeBase64 } from "../util/encoding.js";

/** Length of an X25519 public key in bytes. */
const PUBLIC_KEY_BYTES = 32;

/**
 * Derive a nonce from the ephemeral public key and recipient public key.
 * Uses the first 24 bytes of SHA-512(ephemeral_pk || recipient_pk).
 */
async function deriveNonce(
  ephemeralPk: Uint8Array,
  recipientPk: Uint8Array,
): Promise<Uint8Array> {
  const input = new Uint8Array(PUBLIC_KEY_BYTES * 2);
  input.set(ephemeralPk, 0);
  input.set(recipientPk, PUBLIC_KEY_BYTES);
  const hash = await crypto.subtle.digest("SHA-512", input);
  return new Uint8Array(hash).slice(0, nacl.box.nonceLength);
}

/**
 * Encrypt a message using a sealed box (crypto_box_seal equivalent).
 *
 * Returns base64-encoded ciphertext: ephemeral_pk (32 bytes) || box output.
 * Only the holder of `recipientPublicKey`'s corresponding private key can decrypt.
 */
export async function sealedBoxEncrypt(
  plaintext: Uint8Array,
  recipientPublicKey: Uint8Array,
): Promise<string> {
  const ephemeral = nacl.box.keyPair();
  const nonce = await deriveNonce(ephemeral.publicKey, recipientPublicKey);
  const ciphertext = nacl.box(plaintext, nonce, recipientPublicKey, ephemeral.secretKey);

  if (!ciphertext) {
    throw new Error("sealedBoxEncrypt: encryption failed");
  }

  // Output: ephemeral_pk || ciphertext
  const sealed = new Uint8Array(PUBLIC_KEY_BYTES + ciphertext.length);
  sealed.set(ephemeral.publicKey, 0);
  sealed.set(ciphertext, PUBLIC_KEY_BYTES);
  return encodeBase64(sealed);
}

/**
 * Decrypt a sealed box (crypto_box_seal_open equivalent).
 *
 * Used on the SERVER side (not in the broker for inbound messages).
 * Included here for testing and for potential future use.
 */
export async function sealedBoxDecrypt(
  sealedBase64: string,
  recipientPublicKey: Uint8Array,
  recipientSecretKey: Uint8Array,
): Promise<Uint8Array> {
  const sealed = decodeBase64(sealedBase64);

  if (sealed.length < PUBLIC_KEY_BYTES + nacl.box.overheadLength) {
    throw new Error("sealedBoxDecrypt: ciphertext too short");
  }

  const ephemeralPk = sealed.slice(0, PUBLIC_KEY_BYTES);
  const ciphertext = sealed.slice(PUBLIC_KEY_BYTES);
  const nonce = await deriveNonce(ephemeralPk, recipientPublicKey);
  const plaintext = nacl.box.open(ciphertext, nonce, ephemeralPk, recipientSecretKey);

  if (!plaintext) {
    throw new Error("sealedBoxDecrypt: decryption failed — invalid key or corrupted data");
  }

  return plaintext;
}
