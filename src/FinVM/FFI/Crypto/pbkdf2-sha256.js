// PBKDF2-HMAC-SHA256 KDF via Web Crypto. Floor: 210k iterations (OWASP).

const crypto = globalThis.crypto;
export const PBKDF2_MIN_ITERATIONS = 210_000;

export async function pbkdf2Sha256(passphrase, salt, iterations = PBKDF2_MIN_ITERATIONS) {
  if (iterations < PBKDF2_MIN_ITERATIONS) {
    throw new Error(`PBKDF2 iterations ${iterations} below floor ${PBKDF2_MIN_ITERATIONS}`);
  }
  const encoder = new TextEncoder();
  const baseKey = await crypto.subtle.importKey(
    'raw',
    encoder.encode(passphrase),
    { name: 'PBKDF2' },
    false,
    ['deriveKey']
  );
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations, hash: 'SHA-256' },
    baseKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt', 'wrapKey', 'unwrapKey']
  );
}

export async function pbkdf2Sha256Raw(passphrase, salt, iterations = PBKDF2_MIN_ITERATIONS, lengthBytes = 32) {
  if (iterations < PBKDF2_MIN_ITERATIONS) {
    throw new Error(`PBKDF2 iterations ${iterations} below floor ${PBKDF2_MIN_ITERATIONS}`);
  }
  const encoder = new TextEncoder();
  const baseKey = await crypto.subtle.importKey(
    'raw',
    encoder.encode(passphrase),
    { name: 'PBKDF2' },
    false,
    ['deriveBits']
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt, iterations, hash: 'SHA-256' },
    baseKey,
    lengthBytes * 8
  );
  return new Uint8Array(bits);
}

export function registerPbkdf2Sha256() {
  return {
    id: 'pbkdf2-sha256',
    minIterations: PBKDF2_MIN_ITERATIONS,
    deriveKey: pbkdf2Sha256,
    deriveRaw: pbkdf2Sha256Raw,
  };
}
