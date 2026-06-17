// Bootstrap: register default cipher/KDF/wrap suites.

import { registerCipher, registerKdf, registerWrap } from './registry.js';
import { registerAes256Gcm } from './aes-256-gcm.js';
import { registerPbkdf2Sha256 } from './pbkdf2-sha256.js';
import { registerArgon2id } from './argon2id.js';
import { registerAesgcmKeywrap } from './aesgcm-keywrap.js';
import { registerEciesSecp256k1 } from './ecies-secp256k1.js';

let bootstrapped = false;

export function bootstrapCrypto() {
  if (bootstrapped) return;
  registerCipher('aes-256-gcm', registerAes256Gcm());
  registerKdf('pbkdf2-sha256', registerPbkdf2Sha256());
  registerKdf('argon2id', registerArgon2id());
  registerWrap('aesgcm-keywrap', registerAesgcmKeywrap());
  registerWrap('ecies-secp256k1', registerEciesSecp256k1());
  registerWrap('eth-decrypt', { ...registerEciesSecp256k1(), id: 'eth-decrypt' });
  bootstrapped = true;
}

export * from './registry.js';
export * from './envelope.js';
export * from './dek.js';
export * from './base64.js';
export * from './aes-256-gcm.js';
export * from './pbkdf2-sha256.js';
export * from './argon2id.js';
export * from './aesgcm-keywrap.js';
export * from './ecies-secp256k1.js';
