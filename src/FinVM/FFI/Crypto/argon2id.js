// Argon2id KDF. Uses hash-wasm when available; falls back to PBKDF2 >= 210k.

import { argon2id } from 'hash-wasm';
import { pbkdf2Sha256Raw, PBKDF2_MIN_ITERATIONS } from './pbkdf2-sha256.js';

export const ARGON2_MIN_MEMORY = 65536; // 64 MiB in KiB units for hash-wasm
export const ARGON2_MIN_ITERATIONS = 3;
export const ARGON2_MIN_PARALLELISM = 1;

let argon2Available = null;

async function checkArgon2() {
  if (argon2Available !== null) return argon2Available;
  try {
    const salt = new Uint8Array(16);
    await argon2id({
      password: 'probe',
      salt,
      parallelism: 1,
      iterations: 1,
      memorySize: 65536,
      hashLength: 32,
      outputType: 'binary',
    });
    argon2Available = true;
  } catch {
    argon2Available = false;
  }
  return argon2Available;
}

export async function argon2idDeriveRaw(passphrase, salt, opts = {}) {
  const memorySize = opts.memorySize ?? ARGON2_MIN_MEMORY;
  const iterations = opts.iterations ?? ARGON2_MIN_ITERATIONS;
  const parallelism = opts.parallelism ?? ARGON2_MIN_PARALLELISM;
  const hashLength = opts.hashLength ?? 32;

  if (memorySize < ARGON2_MIN_MEMORY) {
    throw new Error(`Argon2id memory ${memorySize} below floor ${ARGON2_MIN_MEMORY}`);
  }
  if (iterations < ARGON2_MIN_ITERATIONS) {
    throw new Error(`Argon2id iterations ${iterations} below floor ${ARGON2_MIN_ITERATIONS}`);
  }

  if (await checkArgon2()) {
    const hash = await argon2id({
      password: passphrase,
      salt,
      parallelism,
      iterations,
      memorySize,
      hashLength,
      outputType: 'binary',
    });
    return hash instanceof Uint8Array ? hash : new Uint8Array(hash);
  }

  // Fallback: PBKDF2 with elevated iterations (still >= floor).
  const fallbackIterations = Math.max(PBKDF2_MIN_ITERATIONS, iterations * 100_000);
  return pbkdf2Sha256Raw(passphrase, salt, fallbackIterations, hashLength);
}

export async function argon2idDeriveKey(passphrase, salt, opts = {}) {
  const raw = await argon2idDeriveRaw(passphrase, salt, opts);
  return globalThis.crypto.subtle.importKey(
    'raw',
    raw,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt', 'wrapKey', 'unwrapKey']
  );
}

export function registerArgon2id() {
  return {
    id: 'argon2id',
    minMemory: ARGON2_MIN_MEMORY,
    minIterations: ARGON2_MIN_ITERATIONS,
    deriveKey: argon2idDeriveKey,
    deriveRaw: argon2idDeriveRaw,
  };
}
