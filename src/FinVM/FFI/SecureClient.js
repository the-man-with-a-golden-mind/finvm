// JS-friendly helpers for SecureLoader + program decode + sealed run (uncurried PureScript FFI).

import { decodeProgramFileWithInputValues, runJsonProgramResult } from '../../../output/FinVM.Encoding.Json/index.js';
import { Nothing, Just } from '../../../output/Data.Maybe/index.js';
import { loadSecure as loadSecureInner, isSealedProgram, DecryptionFailed } from './SecureLoader.js';
import { redactSecrets } from './KeyProvider.js';
import { runLiveSecure } from '../../../host/secureDriver.mjs';

export { loadSecureInner as loadSecure, isSealedProgram, DecryptionFailed, redactSecrets };

/** Uncurried decode: `decryptedValuesJson` is optional JSON string for inputs.values override. */
export function decodeProgram(source, decryptedValuesJson) {
  const maybeValues = decryptedValuesJson == null
    ? Nothing.value
    : Just.create(decryptedValuesJson);
  return decodeProgramFileWithInputValues(source)(maybeValues);
}

function mergeProgramWithInputs(programJson, inputsValues) {
  if (!inputsValues) return programJson;
  const obj = JSON.parse(programJson);
  obj.inputs = obj.inputs ?? { schema: [], values: {} };
  obj.inputs.values = inputsValues;
  return JSON.stringify(obj);
}

function vmFailed(error) {
  return { ok: false, output: JSON.stringify({ status: 'failed', error: String(error) }) };
}

function vmCompleted(value, extras = {}) {
  return {
    ok: true,
    output: JSON.stringify({ status: 'completed', result: value, ...extras }),
    ...extras,
  };
}

/** Full secure load → decode pipeline for browser/self-host runtimes. */
export async function loadAndDecodeProgram({ grant, keyProvider, program, inputs, db }) {
  const loaded = await loadSecureInner({ grant, keyProvider, program, inputs, db });
  const merged = mergeProgramWithInputs(loaded.programJson, loaded.inputsValues);
  const decoded = decodeProgram(merged);
  return { ...loaded, decoded, runnableSource: merged };
}

/**
 * Sealed program + inputs + DB → decrypt → decode → run interpreter.
 * When `live: true` or a sealed DB bundle is present, runs through the effect
 * driver with ciphertext-only db.commit / output.save egress.
 */
export async function runSealedProgram({ grant, keyProvider, program, inputs, db, live = false, ...opts }) {
  try {
    const { runnableSource, dek, dbBundle, decoded } = await loadAndDecodeProgram({
      grant, keyProvider, program, inputs, db,
    });
    if (decoded.constructor.name === 'Left') {
      return vmFailed(decoded.value0);
    }

    if (live || dbBundle != null) {
      const liveResult = await runLiveSecure(dek, runnableSource, {
        initialDbBlob: dbBundle,
        ...opts,
      });
      return vmCompleted(liveResult.value, {
        egress: liveResult.egress,
        journal: liveResult.journal,
        events: liveResult.events,
        state: liveResult.state,
        syncBlob: liveResult.syncBlob,
      });
    }

    return runJsonProgramResult(runnableSource);
  } catch (e) {
    if (e instanceof DecryptionFailed) {
      return vmFailed(e.message);
    }
    throw e;
  }
}

/** Assert error/snapshot/log strings never contain raw secrets. */
export function assertNoSecrets(text, secrets) {
  for (const s of secrets) {
    if (s && text.includes(s)) {
      throw new Error(`Secret leaked into output: ${s.slice(0, 4)}...`);
    }
  }
}
