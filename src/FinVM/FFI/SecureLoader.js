// SecureLoader: client/self-host decrypt boundary. NEVER import from server bundles.
//
// Build-time guard: this module references browser-only globals so esbuild
// platform=node bundles fail when SecureLoader is included without shimming.

import { bootstrapCrypto, isFencEnvelope, decryptEnvelope, DecryptionFailed, encryptEnvelope } from './Crypto/index.js';
import { unwrapDek, generateDek } from './Crypto/dek.js';
import { redactSecrets } from './KeyProvider.js';

bootstrapCrypto();

// Client-only marker — bundlers targeting pure server without Web Crypto fail here.
const _CLIENT_GUARD = (() => {
  if (typeof globalThis.crypto?.subtle === 'undefined') {
    throw new Error('FINVM_SECURE_CLIENT_ONLY: SecureLoader requires Web Crypto (browser or self-hosted Node >= 20)');
  }
  // Additional marker for platform=node server builds that should not decrypt.
  if (typeof process !== 'undefined' && process.env?.FINVM_SERVER_BUILD === '1') {
    throw new Error('FINVM_SECURE_CLIENT_ONLY: SecureLoader must not be bundled in server builds');
  }
  return true;
})();

export { DecryptionFailed, generateDek, encryptEnvelope, isFencEnvelope, redactSecrets };

/**
 * Detect fenc-wrapped program at load time and unwrap.
 * @param {string|object} source - raw JSON string or parsed object
 * @returns {boolean}
 */
export function isSealedProgram(source) {
  const obj = typeof source === 'string' ? JSON.parse(source) : source;
  return isFencEnvelope(obj) && obj.target === 'program';
}

/**
 * SecureLoader: decrypt encrypted artifacts → plaintext for interpreter.
 *
 * @param {object} params
 * @param {object} params.grant - wrapped DEK grant
 * @param {object} params.keyProvider - from createPassphraseKeyProvider / createWalletKeyProvider
 * @param {string|object} [params.program] - program JSON or fenc envelope
 * @param {object} [params.inputs] - inputs.values (plaintext or fenc envelope)
 * @param {object|string} [params.db] - encrypted DB bundle (fenc envelope target db, or legacy v2)
 * @returns {Promise<{ programJson: string, inputsValues: object|null, dbBundle: string|null, dek: Uint8Array }>}
 */
export async function loadSecure(params) {
  void _CLIENT_GUARD;
  const { grant, keyProvider, program, inputs, db } = params;
  if (!grant || !keyProvider) {
    throw new DecryptionFailed('grant and keyProvider required');
  }

  let dek;
  try {
    dek = await unwrapDek(grant, keyProvider);
  } catch (e) {
    throw e instanceof DecryptionFailed ? e : new DecryptionFailed('DEK unwrap failed', e);
  }

  let programJson;
  if (program == null) {
    throw new DecryptionFailed('program artifact required');
  }
  const programObj = typeof program === 'string' ? JSON.parse(program) : program;
  if (isFencEnvelope(programObj) && programObj.target === 'program') {
    programJson = await decryptEnvelope(dek, programObj);
  } else if (typeof program === 'string' && !isFencEnvelope(programObj)) {
    programJson = program;
  } else if (!isFencEnvelope(programObj)) {
    programJson = JSON.stringify(programObj);
  } else {
    throw new DecryptionFailed('Program envelope target mismatch');
  }

  let inputsValues = null;
  if (inputs != null) {
    if (isFencEnvelope(inputs) && inputs.target === 'inputs') {
      const decrypted = await decryptEnvelope(dek, inputs);
      inputsValues = JSON.parse(decrypted);
    } else if (typeof inputs === 'object') {
      inputsValues = inputs;
    }
  }

  let dbBundle = null;
  if (db != null) {
    if (typeof db === 'string') {
      dbBundle = db;
    } else if (isFencEnvelope(db) && db.target === 'db') {
      dbBundle = JSON.stringify(db);
    } else {
      dbBundle = JSON.stringify(db);
    }
  }

  return { programJson, inputsValues, dbBundle, dek };
}

/**
 * Encrypt outputs/DB for ciphertext-only egress.
 */
export async function sealForPersist(dek, target, plaintext) {
  void _CLIENT_GUARD;
  return encryptEnvelope(dek, target, plaintext);
}

/**
 * Full round-trip helper for tests: seal program + inputs + db under one DEK.
 */
export async function sealArtifacts(dek, { programJson, inputsValues, dbPlaintext }) {
  const program = await encryptEnvelope(dek, 'program', programJson);
  const inputs = inputsValues != null
    ? await encryptEnvelope(dek, 'inputs', JSON.stringify(inputsValues))
    : null;
  const db = dbPlaintext != null
    ? await encryptEnvelope(dek, 'db', dbPlaintext)
    : null;
  return { program, inputs, db };
}

export default { loadSecure, isSealedProgram, sealForPersist, sealArtifacts, DecryptionFailed };
