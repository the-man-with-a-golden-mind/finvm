// AES-256-GCM cipher via Web Crypto (browser + Node >= 20).

const crypto = globalThis.crypto;

export async function importAesKey(rawKeyBytes, extractable = false) {
  return crypto.subtle.importKey(
    'raw',
    rawKeyBytes,
    { name: 'AES-GCM', length: 256 },
    extractable,
    ['encrypt', 'decrypt']
  );
}

export async function aesGcmEncrypt(key, plaintext, iv, aad) {
  const params = { name: 'AES-GCM', iv };
  if (aad && aad.length > 0) params.additionalData = aad;
  const ct = await crypto.subtle.encrypt(params, key, plaintext);
  return new Uint8Array(ct);
}

export async function aesGcmDecrypt(key, ciphertext, iv, aad) {
  const params = { name: 'AES-GCM', iv };
  if (aad && aad.length > 0) params.additionalData = aad;
  const pt = await crypto.subtle.decrypt(params, key, ciphertext);
  return new Uint8Array(pt);
}

export function randomIv(bytes = 12) {
  return crypto.getRandomValues(new Uint8Array(bytes));
}

export function registerAes256Gcm() {
  return {
    id: 'aes-256-gcm',
    ivBytes: 12,
    encrypt: aesGcmEncrypt,
    decrypt: aesGcmDecrypt,
    importKey: importAesKey,
  };
}
