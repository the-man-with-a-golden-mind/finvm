// Secure effect driver wrapper — ciphertext-only egress for persist/sync.

import { runLive } from './driver.mjs';
import { createEncryptedDbStorage, sealOutputPayload } from './encryptedStorage.mjs';
import { createLiveHandlers } from './handlers.mjs';
import { redactSecrets } from '../src/FinVM/FFI/KeyProvider.js';

function assertCiphertextOnly(blob, label) {
  const text = typeof blob === 'string' ? blob : JSON.stringify(blob);
  if (text.includes('alice') || text.includes('"owner"') || text.includes('"balance"')) {
    throw new Error(`${label} must not contain plaintext record fields`);
  }
  if (!text.includes('"fenc"')) {
    throw new Error(`${label} must be an fenc envelope`);
  }
}

/**
 * Live run with encrypted DB storage and sealed sync egress.
 * Effect handlers for db.commit / output.save return opaque fenc blobs only.
 */
export async function runLiveSecure(dek, programSource, opts = {}) {
  const encryptedStorage = createEncryptedDbStorage(dek, {
    initialDbBlob: opts.initialDbBlob ?? null,
    persistence: opts.persistence ?? null,
  });
  const baseHandlers = createLiveHandlers({ ...opts, storage: encryptedStorage });

  const handlers = {
    ...baseHandlers,
    'db.commit': async () => {
      const blob = await encryptedStorage.commit();
      assertCiphertextOnly(blob, 'db.commit egress');
      return blob;
    },
    'output.save': async (p) => {
      const payload = p?.payload ?? p?.value ?? p;
      const sealed = await sealOutputPayload(dek, payload);
      assertCiphertextOnly(sealed, 'output.save egress');
      return sealed;
    },
  };

  const live = await runLive(programSource, { ...opts, handlers });
  const egress = await sealOutputPayload(dek, { result: live.value, state: live.state });

  return {
    value: live.value,
    events: live.events,
    journal: live.journal,
    state: live.state,
    egress,
    syncBlob: typeof egress === 'object' ? JSON.stringify(egress) : egress,
  };
}

/** Safe log helper — never prints secrets. */
export function secureLog(...args) {
  console.log(...args.map((a) => (typeof a === 'object' ? redactSecrets(a) : a)));
}
