/**
 * Base64 encoding/decoding utilities.
 *
 * Uses standard base64 (not URL-safe) for consistency with tweetnacl-util
 * and common Slack/crypto conventions.
 */

/**
 * Encode a Uint8Array to a base64 string.
 */
export function encodeBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]!);
  }
  return btoa(binary);
}

/**
 * Decode a base64 string to a Uint8Array.
 */
export function decodeBase64(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/**
 * Encode a UTF-8 string to Uint8Array.
 */
export function encodeUTF8(str: string): Uint8Array {
  return new TextEncoder().encode(str);
}

/**
 * Decode a Uint8Array to a UTF-8 string.
 */
export function decodeUTF8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}
