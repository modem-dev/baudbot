/**
 * Sealed box encryption — used for inbound (Slack → server) path.
 *
 * The broker encrypts with the server's public key. Only the server's
 * private key can decrypt. The broker CANNOT decrypt sealed boxes.
 *
 * Uses libsodium's native crypto_box_seal / crypto_box_seal_open for
 * interoperability with standard libsodium implementations on the server.
 * The nonce is derived using BLAKE2B(ephemeral_pk || recipient_pk) as
 * per the libsodium spec.
 */

import _sodium from "libsodium-wrappers-sumo";
import { encodeBase64, decodeBase64 } from "../util/encoding.js";

/** Length of an X25519 public key in bytes. */
const PUBLIC_KEY_BYTES = 32;

/** Ensure libsodium is initialized before use. */
async function sodium(): Promise<typeof _sodium> {
  await _sodium.ready;
  return _sodium;
}

/**
 * Encrypt a message using a sealed box (crypto_box_seal).
 *
 * Returns base64-encoded ciphertext (ephemeral_pk || box output).
 * Only the holder of `recipientPublicKey`'s corresponding private key can decrypt.
 *
 * Uses libsodium's native implementation with BLAKE2B nonce derivation
 * for interoperability with standard libsodium on the server side.
 */
export async function sealedBoxEncrypt(
  plaintext: Uint8Array,
  recipientPublicKey: Uint8Array,
): Promise<string> {
  const s = await sodium();
  const sealed = s.crypto_box_seal(plaintext, recipientPublicKey);
  return encodeBase64(sealed);
}

/**
 * Decrypt a sealed box (crypto_box_seal_open).
 *
 * Used on the SERVER side (not in the broker for inbound messages).
 * Included here for testing and for potential future use.
 */
export async function sealedBoxDecrypt(
  sealedBase64: string,
  recipientPublicKey: Uint8Array,
  recipientSecretKey: Uint8Array,
): Promise<Uint8Array> {
  const s = await sodium();
  const sealed = decodeBase64(sealedBase64);

  if (sealed.length < PUBLIC_KEY_BYTES + s.crypto_box_MACBYTES) {
    throw new Error("sealedBoxDecrypt: ciphertext too short");
  }

  try {
    return s.crypto_box_seal_open(sealed, recipientPublicKey, recipientSecretKey);
  } catch {
    throw new Error("sealedBoxDecrypt: decryption failed — invalid key or corrupted data");
  }
}
