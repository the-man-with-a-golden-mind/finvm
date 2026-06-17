/**
 * Secure crypto boundary benchmarks.
 * Run: npm run bench:secure
 */

import { performance } from 'node:perf_hooks';
import {
  bootstrapCrypto,
  generateDek,
  encryptEnvelope,
  decryptEnvelope,
} from '../src/FinVM/FFI/Crypto/index.js';
import { sealArtifacts } from '../src/FinVM/FFI/SecureLoader.js';
import {
  createPassphraseGrant,
  createPassphraseKeyProvider,
  createWalletGrant,
  createWalletKeyProvider,
} from '../src/FinVM/FFI/KeyProvider.js';
import { unwrapDek } from '../src/FinVM/FFI/Crypto/dek.js';
import { runSealedProgram } from '../src/FinVM/FFI/SecureClient.js';
import { runLiveSecure } from '../host/secureDriver.mjs';
import { runJsonProgramResult } from '../output/FinVM.Encoding.Json/index.js';
import { FinVMDatabase } from '../src/FinVM/FFI/Database.js';

bootstrapCrypto();

const PASSPHRASE = 'bench_passphrase_not_a_real_secret';
const WALLET_PRIV = '0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const WARMUP = 3;
const ITERS = 25;

const SAMPLE_PROGRAM = JSON.stringify({
  version: '1.0',
  entrypoint: 'main',
  constants: [{ string: 'x' }],
  functions: {
    main: {
      registerCount: 8,
      instructions: [
        ['LOAD_CONST', 2, 0],
        ['CALL_BUILTIN', 1, 'input.get@1', [2]],
        ['RETURN', 1],
      ],
    },
  },
  inputs: {
    schema: [{ name: 'x', type: 'Int', required: true }],
    values: { x: { int: '42' } },
  },
});

const EFFECT_PROGRAM = JSON.stringify({
  version: '1.0',
  entrypoint: 'main',
  constants: [{ string: 'kIns' }, { string: 'kCommit' }, { string: 't' }, { int: '1' }],
  functions: {
    main: {
      registerCount: 16,
      instructions: [
        ['RECORD_NEW', 0],
        ['LOAD_CONST', 1, 0], ['RECORD_SET', 0, 0, 'key', 1],
        ['LOAD_CONST', 2, 2], ['RECORD_SET', 0, 0, 'table', 2],
        ['RECORD_NEW', 3],
        ['LOAD_CONST', 4, 3], ['RECORD_SET', 3, 3, 'n', 4],
        ['RECORD_SET', 0, 0, 'record', 3],
        ['EFFECT_NEW', 5, 'db.insert', 0],
        ['EFFECT_AWAIT', 5],
        ['RECORD_NEW', 6],
        ['LOAD_CONST', 7, 1], ['RECORD_SET', 6, 6, 'key', 7],
        ['EFFECT_NEW', 8, 'db.commit', 6],
        ['EFFECT_AWAIT', 8],
        ['RETURN', 0],
      ],
    },
  },
});

function median(nums) {
  const sorted = [...nums].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

async function bench(label, fn, { iters = ITERS, warmup = WARMUP } = {}) {
  for (let i = 0; i < warmup; i++) await fn();
  const samples = [];
  for (let i = 0; i < iters; i++) {
    const t0 = performance.now();
    await fn();
    samples.push(performance.now() - t0);
  }
  const med = median(samples);
  const min = Math.min(...samples);
  const max = Math.max(...samples);
  console.log(`  ${label.padEnd(42)} ${med.toFixed(2).padStart(8)} ms  (min ${min.toFixed(2)}, max ${max.toFixed(2)}, n=${iters})`);
  return med;
}

async function main() {
  console.log('FinVM secure boundary benchmarks\n');

  const dek = generateDek();
  const dbPlain = new FinVMDatabase();
  dbPlain.insert('t', { v: 1 });
  const dbPlaintext = JSON.stringify({
    sequence: 1,
    tables: [['t', Array.from(dbPlain.tables.get('t').entries())]],
  });

  const sealed = await sealArtifacts(dek, {
    programJson: SAMPLE_PROGRAM,
    inputsValues: { x: { int: '42' } },
    dbPlaintext,
  });
  const grant = await createPassphraseGrant(PASSPHRASE, dek);
  const walletGrant = await createWalletGrant(WALLET_PRIV, dek);
  const keyProvider = createPassphraseKeyProvider(PASSPHRASE);
  const walletProvider = createWalletKeyProvider(WALLET_PRIV);

  console.log('--- Crypto primitives ---');
  await bench('encryptEnvelope(program)', async () => {
    await encryptEnvelope(dek, 'program', SAMPLE_PROGRAM);
  });
  await bench('decryptEnvelope(program)', async () => {
    await decryptEnvelope(dek, sealed.program);
  });
  await bench('sealArtifacts(program+inputs+db)', async () => {
    await sealArtifacts(dek, {
      programJson: SAMPLE_PROGRAM,
      inputsValues: { x: { int: '42' } },
      dbPlaintext,
    });
  });

  console.log('\n--- Key unwrap ---');
  await bench('passphrase KEK unwrap (Argon2id/PBKDF2)', async () => {
    await unwrapDek(grant, keyProvider);
  });
  await bench('wallet ECIES unwrap', async () => {
    await unwrapDek(walletGrant, walletProvider);
  });

  console.log('\n--- End-to-end pipelines ---');
  await bench('runJsonProgramResult (plaintext baseline)', async () => {
    runJsonProgramResult(SAMPLE_PROGRAM);
  });
  await bench('runSealedProgram (decrypt+decode+run)', async () => {
    await runSealedProgram({
      grant,
      keyProvider,
      program: sealed.program,
      inputs: sealed.inputs,
      db: sealed.db,
    });
  });
  await bench('runLiveSecure (effects+egress)', async () => {
    await runLiveSecure(dek, EFFECT_PROGRAM);
  });

  console.log('\n--- DB encrypted export ---');
  const encDb = new FinVMDatabase();
  await encDb.setDEK(dek);
  encDb.insert('accounts', { owner: 'bench', balance: 100 });
  await bench('FinVMDatabase.exportEncrypted (DEK)', async () => {
    await encDb.exportEncrypted();
  });

  console.log('\nDone.');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
