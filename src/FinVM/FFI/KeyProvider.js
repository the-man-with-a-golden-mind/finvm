// KeyProvider: derives KEK from passphrase (Argon2id / PBKDF2) or wallet (ECIES).

import { getKdf } from './Crypto/registry.js';
import { argon2idDeriveRaw } from './Crypto/argon2id.js';
import { pbkdf2Sha256Raw, PBKDF2_MIN_ITERATIONS } from './Crypto/pbkdf2-sha256.js';
import { privateKeyFromHex } from './Crypto/ecies-secp256k1.js';
import { base64ToBytes } from './Crypto/base64.js';
import { bootstrapCrypto } from './Crypto/index.js';

bootstrapCrypto();

const REDACTED = '[REDACTED]';

export function redactSecrets(obj) {
  if (obj == null || typeof obj !== 'object') return obj;
  if (obj instanceof Uint8Array || obj instanceof ArrayBuffer) return REDACTED;
  if (Array.isArray(obj)) return obj.map(redactSecrets);
  const out = {};
  for (const [k, v] of Object.entries(obj)) {
    const lk = k.toLowerCase();
    if (lk.includes('passphrase') || lk.includes('password') || lk.includes('secret')
      || lk.includes('privatekey') || lk.includes('private_key') || lk === 'kek'
      || lk === 'dek' || lk.includes('signature') || lk === 'key') {
      out[k] = REDACTED;
    } else {
      out[k] = redactSecrets(v);
    }
  }
  return out;
}

export function createPassphraseKeyProvider(passphrase, opts = {}) {
  if (!passphrase || typeof passphrase !== 'string') {
    throw new Error('Passphrase required');
  }
  const kdfId = opts.kdf ?? 'argon2id';
  return {
    type: 'passphrase',
    async deriveKEK(grant) {
      const salt = grant.salt ? base64ToBytes(grant.salt) : new Uint8Array(16);
      const kdfParams = grant.kdfParams ?? {};
      if (kdfId === 'argon2id' || grant.kdf === 'argon2id') {
        return argon2idDeriveRaw(passphrase, salt, {
          memorySize: kdfParams.memorySize,
          iterations: kdfParams.iterations,
          parallelism: kdfParams.parallelism,
        });
      }
      const iterations = Math.max(PBKDF2_MIN_ITERATIONS, kdfParams.iterations ?? PBKDF2_MIN_ITERATIONS);
      return pbkdf2Sha256Raw(passphrase, salt, iterations);
    },
    async getWalletPrivateKey() {
      return null;
    },
    toSafeJSON() {
      return { type: 'passphrase', kdf: kdfId };
    },
  };
}

export function createWalletKeyProvider(privateKeyHex) {
  const privKey = privateKeyFromHex(privateKeyHex);
  return {
    type: 'wallet',
    async deriveKEK(_grant) {
      return null;
    },
    async getWalletPrivateKey() {
      return privKey;
    },
    toSafeJSON() {
      return { type: 'wallet' };
    },
  };
}

export async function createPassphraseGrant(passphrase, dekBytes, opts = {}) {
  const { wrapDekWithKek } = await import('./Crypto/aesgcm-keywrap.js');
  const kdfId = opts.kdf ?? 'argon2id';
  const salt = globalThis.crypto.getRandomValues(new Uint8Array(16));
  let kek;
  if (kdfId === 'argon2id') {
    kek = await argon2idDeriveRaw(passphrase, salt, opts.kdfParams ?? {});
  } else {
    const kdf = getKdf('pbkdf2-sha256');
    kek = await kdf.deriveRaw(passphrase, salt, opts.kdfParams?.iterations);
  }
  const { bytesToBase64 } = await import('./Crypto/base64.js');
  const wrapped = await wrapDekWithKek(kek, dekBytes);
  return {
    ...wrapped,
    kdf: kdfId,
    salt: bytesToBase64(salt),
    kdfParams: opts.kdfParams ?? {},
  };
}

export async function createWalletGrant(privateKeyHex, dekBytes) {
  const { wrapDekWithEcies, pubKeyFromPrivate } = await import('./Crypto/ecies-secp256k1.js');
  const { bytesToBase64 } = await import('./Crypto/base64.js');
  const priv = privateKeyFromHex(privateKeyHex);
  const pub = pubKeyFromPrivate(priv);
  const wrapped = await wrapDekWithEcies(pub, dekBytes);
  return {
    ...wrapped,
    recipientPub: bytesToBase64(pub),
  };
}
