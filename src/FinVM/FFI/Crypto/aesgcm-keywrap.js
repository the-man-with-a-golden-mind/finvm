// AES-GCM key wrap: KEK wraps a raw DEK with a dedicated AAD.

import { aesGcmEncrypt, aesGcmDecrypt, importAesKey, randomIv } from './aes-256-gcm.js';
import { bytesToBase64, base64ToBytes } from './base64.js';

const WRAP_AAD = new TextEncoder().encode('finvm:dek-wrap');

export async function wrapDekWithKek(kekBytes, dekBytes) {
  const kek = await importAesKey(kekBytes);
  const iv = randomIv(12);
  const ct = await aesGcmEncrypt(kek, dekBytes, iv, WRAP_AAD);
  return {
    wrap: 'aesgcm-keywrap',
    iv: bytesToBase64(iv),
    ct: bytesToBase64(ct),
  };
}

export async function unwrapDekWithKek(kekBytes, grant) {
  if (grant.wrap !== 'aesgcm-keywrap') {
    throw new Error(`Expected aesgcm-keywrap, got ${grant.wrap}`);
  }
  const kek = await importAesKey(kekBytes);
  const iv = base64ToBytes(grant.iv);
  const ct = base64ToBytes(grant.ct);
  const dek = await aesGcmDecrypt(kek, ct, iv, WRAP_AAD);
  if (dek.length !== 32) throw new Error('DEK must be 256 bits');
  return dek;
}

export function registerAesgcmKeywrap() {
  return {
    id: 'aesgcm-keywrap',
    wrap: wrapDekWithKek,
    unwrap: unwrapDekWithKek,
  };
}
