// ECIES-secp256k1 DEK wrap/unwrap (Ethereum-compatible ECDH + AES-GCM).

import { secp256k1 } from '@noble/curves/secp256k1.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { bytesToBase64, base64ToBytes } from './base64.js';
import { aesGcmEncrypt, aesGcmDecrypt, importAesKey, randomIv } from './aes-256-gcm.js';

const WRAP_AAD = new TextEncoder().encode('finvm:ecies-dek');

function deriveSharedAesKey(sharedSecret) {
  const keyMaterial = sha256(sharedSecret);
  return keyMaterial;
}

function normalizePrivKey(privKeyBytes) {
  if (privKeyBytes.length === 32) return privKeyBytes;
  throw new Error('Private key must be 32 bytes');
}

export function generateEphemeralKeypair() {
  const priv = secp256k1.utils.randomSecretKey();
  const pub = secp256k1.getPublicKey(priv);
  return { privateKey: priv, publicKey: pub };
}

export async function wrapDekWithEcies(recipientPubKeyBytes, dekBytes) {
  const ephemeral = generateEphemeralKeypair();
  const sharedPoint = secp256k1.getSharedSecret(ephemeral.privateKey, recipientPubKeyBytes);
  const aesKeyBytes = deriveSharedAesKey(sharedPoint.slice(1, 33));
  const aesKey = await importAesKey(aesKeyBytes);
  const iv = randomIv(12);
  const ct = await aesGcmEncrypt(aesKey, dekBytes, iv, WRAP_AAD);
  return {
    wrap: 'ecies-secp256k1',
    ephemeralPub: bytesToBase64(ephemeral.publicKey),
    iv: bytesToBase64(iv),
    ct: bytesToBase64(ct),
  };
}

export async function unwrapDekWithEcies(recipientPrivKeyBytes, grant) {
  if (grant.wrap !== 'ecies-secp256k1' && grant.wrap !== 'eth-decrypt') {
    throw new Error(`Expected ecies-secp256k1 or eth-decrypt, got ${grant.wrap}`);
  }
  const priv = normalizePrivKey(recipientPrivKeyBytes);
  const ephemeralPub = base64ToBytes(grant.ephemeralPub);
  const sharedPoint = secp256k1.getSharedSecret(priv, ephemeralPub);
  const aesKeyBytes = deriveSharedAesKey(sharedPoint.slice(1, 33));
  const aesKey = await importAesKey(aesKeyBytes);
  const iv = base64ToBytes(grant.iv);
  const ct = base64ToBytes(grant.ct);
  const dek = await aesGcmDecrypt(aesKey, ct, iv, WRAP_AAD);
  if (dek.length !== 32) throw new Error('DEK must be 256 bits');
  return dek;
}

export function registerEciesSecp256k1() {
  return {
    id: 'ecies-secp256k1',
    wrap: wrapDekWithEcies,
    unwrap: unwrapDekWithEcies,
  };
}

// Ethereum-style eth_decrypt compatible unwrap for wallet grants.
export async function unwrapDekEthDecrypt(recipientPrivKeyBytes, grant) {
  return unwrapDekWithEcies(recipientPrivKeyBytes, grant);
}

export function pubKeyFromPrivate(privKeyBytes) {
  return secp256k1.getPublicKey(normalizePrivKey(privKeyBytes));
}

export function privateKeyFromHex(hex) {
  const clean = hex.startsWith('0x') ? hex.slice(2) : hex;
  const bytes = new Uint8Array(clean.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return normalizePrivKey(bytes);
}
