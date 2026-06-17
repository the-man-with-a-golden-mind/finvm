// DEK generation, wrap (tooling), and unwrap (runtime).

import { getWrap } from './registry.js';
import { DecryptionFailed } from './envelope.js';

export function generateDek() {
  return globalThis.crypto.getRandomValues(new Uint8Array(32));
}

export async function wrapDek(dekBytes, wrapId, wrappingMaterial) {
  const wrap = getWrap(wrapId);
  return wrap.wrap(wrappingMaterial, dekBytes);
}

export async function unwrapDek(grant, keyProvider) {
  try {
    const wrapId = grant.wrap;
    const wrap = getWrap(wrapId);
    if (wrapId === 'ecies-secp256k1' || wrapId === 'eth-decrypt') {
      const privKey = await keyProvider.getWalletPrivateKey();
      if (!privKey) throw new DecryptionFailed('Wallet private key required for ECIES unwrap');
      return wrap.unwrap(privKey, grant);
    }
    if (wrapId === 'aesgcm-keywrap') {
      const kek = await keyProvider.deriveKEK(grant);
      if (!kek) throw new DecryptionFailed('KEK derivation failed');
      return wrap.unwrap(kek, grant);
    }
    throw new DecryptionFailed(`Unknown wrap algorithm: ${wrapId}`);
  } catch (e) {
    if (e instanceof DecryptionFailed) throw e;
    throw new DecryptionFailed('DEK unwrap failed', e);
  }
}
