// Shared fenc envelope format — AEAD encrypt/decrypt with target-bound AAD.

import { bytesToBase64, base64ToBytes } from './base64.js';
import { importAesKey, aesGcmEncrypt, aesGcmDecrypt, randomIv } from './aes-256-gcm.js';
import { getCipher } from './registry.js';

export const FENC_VERSION = 1;
export const VALID_TARGETS = new Set(['program', 'inputs', 'db', 'output']);

export function aadForTarget(target) {
  if (!VALID_TARGETS.has(target)) throw new Error(`Invalid envelope target: ${target}`);
  return new TextEncoder().encode(`finvm:${target}`);
}

export function isFencEnvelope(obj) {
  return obj && typeof obj === 'object' && obj.fenc === FENC_VERSION
    && typeof obj.target === 'string' && typeof obj.cipher === 'string'
    && typeof obj.iv === 'string' && typeof obj.ct === 'string';
}

export function buildEnvelope(target, cipher, iv, ct) {
  return {
    fenc: FENC_VERSION,
    target,
    cipher,
    iv: typeof iv === 'string' ? iv : bytesToBase64(iv),
    aad: `finvm:${target}`,
    ct: typeof ct === 'string' ? ct : bytesToBase64(ct),
  };
}

export class DecryptionFailed extends Error {
  constructor(message, cause) {
    super(`DecryptionFailed: ${message}`);
    this.name = 'DecryptionFailed';
    this.code = 'DecryptionFailed';
    if (cause) this.cause = cause;
  }
}

export async function encryptEnvelope(dekBytes, target, plaintext, cipherId = 'aes-256-gcm') {
  if (!VALID_TARGETS.has(target)) throw new Error(`Invalid target: ${target}`);
  const cipher = getCipher(cipherId);
  const key = await importAesKey(dekBytes);
  const iv = randomIv(cipher.ivBytes ?? 12);
  const aad = aadForTarget(target);
  const pt = typeof plaintext === 'string'
    ? new TextEncoder().encode(plaintext)
    : plaintext;
  const ct = await cipher.encrypt(key, pt, iv, aad);
  return buildEnvelope(target, cipherId, iv, ct);
}

export async function decryptEnvelope(dekBytes, envelope) {
  if (!isFencEnvelope(envelope)) {
    throw new DecryptionFailed('Not a valid fenc envelope');
  }
  const expectedAad = `finvm:${envelope.target}`;
  if (envelope.aad && envelope.aad !== expectedAad) {
    throw new DecryptionFailed(`AAD mismatch: expected ${expectedAad}, got ${envelope.aad}`);
  }
  try {
    const cipher = getCipher(envelope.cipher);
    const key = await importAesKey(dekBytes);
    const iv = base64ToBytes(envelope.iv);
    const ct = base64ToBytes(envelope.ct);
    const aad = aadForTarget(envelope.target);
    const pt = await cipher.decrypt(key, ct, iv, aad);
    return new TextDecoder().decode(pt);
  } catch (e) {
    throw new DecryptionFailed('Envelope decryption failed (tag/AAD/fingerprint mismatch)', e);
  }
}

export async function decryptEnvelopeBytes(dekBytes, envelope) {
  const text = await decryptEnvelope(dekBytes, envelope);
  return new TextEncoder().encode(text);
}

export async function encryptEnvelopeBytes(dekBytes, target, plaintextBytes, cipherId = 'aes-256-gcm') {
  const cipher = getCipher(cipherId);
  const key = await importAesKey(dekBytes);
  const iv = randomIv(cipher.ivBytes ?? 12);
  const aad = aadForTarget(target);
  const ct = await cipher.encrypt(key, plaintextBytes, iv, aad);
  return buildEnvelope(target, cipherId, iv, ct);
}
