// Browser/self-host secure client entry — exports SecureLoader + KeyProvider.
// Do NOT import this from server-side platform bundles.

export {
  loadSecure,
  isSealedProgram,
  sealForPersist,
  sealArtifacts,
  DecryptionFailed,
  generateDek,
  encryptEnvelope,
  isFencEnvelope,
  redactSecrets,
} from '../src/FinVM/FFI/SecureLoader.js';

export {
  createPassphraseKeyProvider,
  createWalletKeyProvider,
  createPassphraseGrant,
  createWalletGrant,
} from '../src/FinVM/FFI/KeyProvider.js';

export {
  decodeProgram,
  loadAndDecodeProgram,
  runSealedProgram,
  assertNoSecrets,
} from '../src/FinVM/FFI/SecureClient.js';

export { createEncryptedDbStorage, sealOutputPayload, sealSyncPayload } from './encryptedStorage.mjs';
export { runLiveSecure, secureLog } from './secureDriver.mjs';

export { FinVMDatabase } from '../src/FinVM/FFI/Database.js';
