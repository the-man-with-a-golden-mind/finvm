/**
 * Full platform ↔ client E2E simulation.
 *
 * Models the PROMPT 1 boundary:
 *   platform stores ciphertext + wrapped grant only
 *   client unwraps DEK → decrypts → runs → ciphertext egress
 *   wrong key / tamper → DecryptionFailed, no execution
 */

import assert from 'node:assert';
import 'fake-indexeddb/auto';
import { performance } from 'node:perf_hooks';
import * as fs from 'node:fs/promises';
import {
  generateDek,
  sealArtifacts,
  createPassphraseGrant,
  createPassphraseKeyProvider,
  createWalletGrant,
  createWalletKeyProvider,
} from '../host/secure.mjs';
import {
  bootstrapCrypto,
  decryptEnvelope,
  DecryptionFailed,
} from '../src/FinVM/FFI/Crypto/index.js';
import { runSealedProgram, assertNoSecrets, decodeProgram } from '../src/FinVM/FFI/SecureClient.js';
import { runLiveSecure } from '../host/secureDriver.mjs';
import { runLive, runReplay, valueToJs } from '../host/driver.mjs';
import { createEncryptedDbStorage } from '../host/encryptedStorage.mjs';
import { createLiveHandlers } from '../host/handlers.mjs';
import { FinVMDatabase } from '../src/FinVM/FFI/Database.js';
import { createIndexedDbPersistence, createFilePersistence } from '../src/FinVM/FFI/db-persistence.js';
import { runJsonProgramResult } from '../output/FinVM.Encoding.Json/index.js';

bootstrapCrypto();

const PASSPHRASE = 'platform_e2e_passphrase_never_log_this';
const WALLET_PRIV = '0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/** input.get@1 → db.insert → db.commit → return input value */
const FULL_STACK_PROGRAM = {
  version: '1.0',
  entrypoint: 'main',
  constants: [
    { string: 'x' },
    { string: 'kIns' },
    { string: 'kCommit' },
    { string: 'ledger' },
  ],
  inputs: {
    schema: [{ name: 'x', type: 'Int', required: true }],
    values: { x: { int: '42' } },
  },
  functions: {
    main: {
      registerCount: 20,
      instructions: [
        ['LOAD_CONST', 2, 0],
        ['CALL_BUILTIN', 1, 'input.get@1', [2]],
        ['RECORD_NEW', 3],
        ['RECORD_SET', 3, 3, 'v', 1],
        ['RECORD_NEW', 5],
        ['LOAD_CONST', 6, 1], ['RECORD_SET', 5, 5, 'key', 6],
        ['LOAD_CONST', 7, 3], ['RECORD_SET', 5, 5, 'table', 7],
        ['RECORD_SET', 5, 5, 'record', 3],
        ['EFFECT_NEW', 8, 'db.insert', 5],
        ['EFFECT_AWAIT', 8],
        ['RECORD_NEW', 9],
        ['LOAD_CONST', 10, 2], ['RECORD_SET', 9, 9, 'key', 10],
        ['EFFECT_NEW', 11, 'db.commit', 9],
        ['EFFECT_AWAIT', 11],
        ['RETURN', 1],
      ],
    },
  },
};

const SECRET_MARKERS = ['alice', 'passphrase', 'secret', PASSPHRASE];

function assertCiphertextOnly(value, label, extraSecrets = []) {
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  assert.ok(text.includes('"fenc"'), `${label} must be fenc ciphertext`);
  for (const marker of [...SECRET_MARKERS, ...extraSecrets]) {
    assert.ok(!text.includes(marker), `${label} must not contain plaintext marker: ${marker}`);
  }
}

function vaultJson(vault) {
  return JSON.stringify(vault);
}

/** Platform-side store: ciphertext artifacts + wrapped grant only. */
function createPlatformVault({ grant, program, inputs, db }) {
  return Object.freeze({
    grant,
    program,
    inputs,
    db,
    storedAt: Date.now(),
  });
}

function assertPlatformVault(vault, secrets) {
  const blob = vaultJson(vault);
  assertCiphertextOnly(vault.program, 'vault.program');
  assertCiphertextOnly(vault.inputs, 'vault.inputs');
  assertCiphertextOnly(vault.db, 'vault.db');
  assert.ok(vault.grant?.ct, 'vault.grant must have wrapped DEK ciphertext');
  assert.ok(!vault.grant?.dek, 'platform vault must not contain raw DEK');
  assertNoSecrets(blob, secrets);
}

function journalResultText(entry) {
  const js = valueToJs(entry?.result);
  return typeof js === 'string' ? js : JSON.stringify(js);
}

async function simulatePassphraseClientRun(vault, passphrase) {
  const keyProvider = createPassphraseKeyProvider(passphrase);
  return runSealedProgram({
    grant: vault.grant,
    keyProvider,
    program: vault.program,
    inputs: vault.inputs,
    db: vault.db,
  });
}

async function testPlatformPassphraseSimulation() {
  console.log('1. Platform vault (ciphertext-only) → client run → ciphertext egress...');
  const dek = generateDek();
  const programJson = JSON.stringify(FULL_STACK_PROGRAM);

  const dbPlain = new FinVMDatabase();
  dbPlain.insert('seed', { seeded: true });
  const dbPlaintext = JSON.stringify({
    sequence: 1,
    tables: [['seed', Array.from(dbPlain.tables.get('seed').entries())]],
  });

  const sealed = await sealArtifacts(dek, {
    programJson,
    inputsValues: FULL_STACK_PROGRAM.inputs.values,
    dbPlaintext,
  });
  const grant = await createPassphraseGrant(PASSPHRASE, dek);
  const vault = createPlatformVault({
    grant,
    program: sealed.program,
    inputs: sealed.inputs,
    db: sealed.db,
  });

  assertPlatformVault(vault, [PASSPHRASE, dek]);

  const client = await simulatePassphraseClientRun(vault, PASSPHRASE);
  assert.strictEqual(client.ok, true, client.output);
  assert.ok(client.egress?.target === 'output');

  const commitEntry = client.journal?.find((e) => e.type_ === 'db.commit');
  assert.ok(commitEntry, 'client must journal db.commit');
  assertCiphertextOnly(journalResultText(commitEntry), 'db.commit journal result');

  const parsed = JSON.parse(client.output);
  assert.strictEqual(parsed.result?.int ?? parsed.result, 42);

  const plainTwin = await runLive(programJson, {
    handlers: createLiveHandlers({ storage: createEncryptedDbStorage(dek) }),
  });
  assert.strictEqual(plainTwin.value?.int ?? plainTwin.value, parsed.result?.int ?? parsed.result);

  assertNoSecrets(JSON.stringify(client), [PASSPHRASE, dek]);
  console.log('   OK');
}

async function testWalletSimulation() {
  console.log('2. Wallet grant simulation (right key / wrong key)...');
  const dek = generateDek();
  const inputOnlyProgram = {
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
      values: { x: { int: '7' } },
    },
  };
  const programJson = JSON.stringify(inputOnlyProgram);

  const sealed = await sealArtifacts(dek, {
    programJson,
    inputsValues: inputOnlyProgram.inputs.values,
    dbPlaintext: null,
  });
  const grant = await createWalletGrant(WALLET_PRIV, dek);
  const vault = createPlatformVault({
    grant,
    program: sealed.program,
    inputs: sealed.inputs,
    db: null,
  });

  const ok = await runSealedProgram({
    grant: vault.grant,
    keyProvider: createWalletKeyProvider(WALLET_PRIV),
    program: vault.program,
    inputs: vault.inputs,
  });
  assert.strictEqual(ok.ok, true);
  assert.ok(JSON.parse(ok.output).result?.int === 7 || ok.output.includes('7'));

  const wrongPriv = '0xfedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
  const bad = await runSealedProgram({
    grant: vault.grant,
    keyProvider: createWalletKeyProvider(wrongPriv),
    program: vault.program,
    inputs: vault.inputs,
  });
  assert.strictEqual(bad.ok, false);
  assert.ok(bad.output.includes('DecryptionFailed'));
  console.log('   OK');
}

async function testTamperAndWrongKeySimulation() {
  console.log('3. Tampered ciphertext + wrong passphrase fail closed...');
  const dek = generateDek();
  const sealed = await sealArtifacts(dek, {
    programJson: JSON.stringify(FULL_STACK_PROGRAM),
    inputsValues: FULL_STACK_PROGRAM.inputs.values,
    dbPlaintext: null,
  });
  const grant = await createPassphraseGrant(PASSPHRASE, dek);
  const vault = createPlatformVault({
    grant,
    program: sealed.program,
    inputs: sealed.inputs,
    db: null,
  });

  const wrongPass = await simulatePassphraseClientRun(vault, 'totally_wrong_passphrase');
  assert.strictEqual(wrongPass.ok, false);
  assert.ok(wrongPass.output.includes('DecryptionFailed'));
  assert.ok(!wrongPass.output.includes('completed'));

  const tamperedVault = createPlatformVault({
    grant,
    program: { ...sealed.program, ct: sealed.program.ct.slice(0, -4) + 'AAAA' },
    inputs: sealed.inputs,
    db: null,
  });
  const tampered = await simulatePassphraseClientRun(tamperedVault, PASSPHRASE);
  assert.strictEqual(tampered.ok, false);
  assert.ok(tampered.output.includes('DecryptionFailed'));
  console.log('   OK');
}

async function testPersistenceRoundTripSimulation() {
  console.log('4. Post-run persistence: Node file + IndexedDB twins...');
  const dek = generateDek();
  const dbFile = '.finvm-platform-e2e.db';
  const filePersistence = createFilePersistence(dbFile);
  try { await fs.unlink(dbFile); } catch {}

  const live = await runLiveSecure(dek, JSON.stringify(FULL_STACK_PROGRAM));
  const commitEntry = live.journal.find((e) => e.type_ === 'db.commit');
  const commitBlob = journalResultText(commitEntry);

  const nodeDb = new FinVMDatabase({ persistence: filePersistence });
  await nodeDb.setDEK(dek);
  await nodeDb.importEncrypted(commitBlob);
  await nodeDb.commit();
  const nodeFile = await fs.readFile(dbFile, 'utf8');
  assertCiphertextOnly(nodeFile, 'node commit file');

  const nodeReload = new FinVMDatabase({ persistence: filePersistence });
  await nodeReload.setDEK(dek);
  await nodeReload.load();
  assert.ok(nodeReload.hashTable('ledger').length > 10);

  const idbPersistence = createIndexedDbPersistence({
    dbName: 'finvm_platform_e2e',
    storeName: 'kv',
    key: 'bundle',
  });
  const idbDb = new FinVMDatabase({ persistence: idbPersistence });
  await idbDb.setDEK(dek);
  await idbDb.importEncrypted(commitBlob);
  await idbDb.commit();
  const idbBlob = await idbPersistence.read();
  assertCiphertextOnly(idbBlob, 'IndexedDB blob');

  const idbReload = new FinVMDatabase({ persistence: idbPersistence });
  await idbReload.setDEK(dek);
  await idbReload.load();
  assert.strictEqual(idbReload.hashTable('ledger'), nodeReload.hashTable('ledger'));

  try { await fs.unlink(dbFile); } catch {}
  console.log('   OK');
}

async function testReplayDeterminismSimulation() {
  console.log('5. Live → replay determinism (zero I/O replay)...');
  const dek = generateDek();
  const programSource = JSON.stringify(FULL_STACK_PROGRAM);
  const live = await runLiveSecure(dek, programSource);
  const replay = runReplay(programSource, live.journal);
  assert.deepStrictEqual(replay.value, live.value);
  assertNoSecrets(JSON.stringify(live.journal), [PASSPHRASE, dek]);
  console.log('   OK');
}

async function testAcceptanceChecklist() {
  console.log('6. PROMPT 1 acceptance checklist (automated audit)...');
  const dek = generateDek();
  const programJson = JSON.stringify(FULL_STACK_PROGRAM);
  const inputsValues = FULL_STACK_PROGRAM.inputs.values;
  const dbPlaintext = JSON.stringify({ sequence: 0, tables: [] });

  const sealed = await sealArtifacts(dek, { programJson, inputsValues, dbPlaintext });

  // DEK round-trip byte-identical
  assert.strictEqual(await decryptEnvelope(dek, sealed.program), programJson);
  assert.deepStrictEqual(
    JSON.parse(await decryptEnvelope(dek, sealed.inputs)),
    inputsValues,
  );
  assert.strictEqual(await decryptEnvelope(dek, sealed.db), dbPlaintext);

  // swapped target fails
  const swapped = { ...sealed.program, target: 'inputs', aad: 'finvm:inputs' };
  await assert.rejects(() => decryptEnvelope(dek, swapped), DecryptionFailed);

  // fenc-at-load rejected
  const fencDecoded = decodeProgram(JSON.stringify(sealed.program));
  assert.strictEqual(fencDecoded.constructor.name, 'Left');
  assert.ok(fencDecoded.value0.includes('DecryptionFailed'));

  // server bundle guard symbolically: SecureLoader import blocked under FINVM_SERVER_BUILD
  const { spawnSync } = await import('node:child_process');
  const guard = spawnSync(process.execPath, [
    '--input-type=module',
    '-e',
    "import('./src/FinVM/FFI/SecureLoader.js')",
  ], {
    env: { ...process.env, FINVM_SERVER_BUILD: '1' },
    encoding: 'utf8',
  });
  assert.notStrictEqual(guard.status, 0);

  // plaintext twin determinism (pure input.get program, no effects)
  const pureProgram = JSON.stringify({
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
      values: { x: { int: '1' } },
    },
  });
  const a = runJsonProgramResult(pureProgram);
  const b = runJsonProgramResult(pureProgram);
  assert.strictEqual(a.output, b.output);

  console.log('   OK (all checklist items verified)');
}

async function testPlaintextTwinViaEffects() {
  console.log('7. Plaintext twin via effect driver matches sealed live result...');
  const dek = generateDek();
  const programSource = JSON.stringify(FULL_STACK_PROGRAM);

  const plainLive = await runLive(programSource, {
    handlers: createLiveHandlers({ storage: createEncryptedDbStorage(dek) }),
  });
  const sealedLive = await runLiveSecure(dek, programSource);

  assert.deepStrictEqual(plainLive.value, sealedLive.value);
  assert.ok(sealedLive.journal.find((e) => e.type_ === 'db.commit'));
  console.log('   OK');
}

async function run() {
  console.log('Secure platform E2E simulation\n');
  const t0 = performance.now();
  await testPlatformPassphraseSimulation();
  await testWalletSimulation();
  await testTamperAndWrongKeySimulation();
  await testPersistenceRoundTripSimulation();
  await testReplayDeterminismSimulation();
  await testAcceptanceChecklist();
  await testPlaintextTwinViaEffects();
  const ms = (performance.now() - t0).toFixed(1);
  console.log(`\nSecure platform E2E simulation passed! (${ms}ms total)`);
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
