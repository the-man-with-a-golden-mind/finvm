import assert from 'node:assert';
import {
  generateDek,
  encryptEnvelope,
  sealArtifacts,
  createPassphraseGrant,
  createPassphraseKeyProvider,
} from '../host/secure.mjs';
import { runSealedProgram, assertNoSecrets, decodeProgram } from '../src/FinVM/FFI/SecureClient.js';
import { FinVMDatabase } from '../src/FinVM/FFI/Database.js';
import { runJsonProgramResult } from '../output/FinVM.Encoding.Json/index.js';
import * as fs from 'node:fs/promises';

const PASSPHRASE = 'e2e_test_passphrase_do_not_log_me';

const PLAIN_PROGRAM = {
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
    values: { x: { int: '99' } },
  },
};

async function testSealedRunE2E() {
  console.log('1. Sealed program + inputs + DB run after correct key derivation...');
  const dek = generateDek();
  const programJson = JSON.stringify(PLAIN_PROGRAM);
  const inputsValues = PLAIN_PROGRAM.inputs.values;

  const dbPlain = new FinVMDatabase();
  await dbPlain.insert('t', { v: 1 });
  const plainHash = dbPlain.hashTable('t');
  const dbPlaintext = JSON.stringify({
    sequence: 1,
    tables: [['t', Array.from(dbPlain.tables.get('t').entries())]],
  });

  const sealed = await sealArtifacts(dek, { programJson, inputsValues, dbPlaintext });
  const grant = await createPassphraseGrant(PASSPHRASE, dek);
  const keyProvider = createPassphraseKeyProvider(PASSPHRASE);

  const result = await runSealedProgram({
    grant,
    keyProvider,
    program: sealed.program,
    inputs: sealed.inputs,
    db: sealed.db,
  });

  assert.strictEqual(result.ok, true, result.output);
  assert.ok(result.output.includes('"status":"completed"') || result.output.includes('"status": "completed"'));
  assert.ok(result.output.includes('99'));
  assertNoSecrets(result.output, [PASSPHRASE, dek]);

  // Plaintext twin: same program JSON run directly
  const twin = runJsonProgramResult(programJson);
  assert.strictEqual(twin.ok, true);
  assertNoSecrets(twin.output, [PASSPHRASE, dek]);
  console.log('   OK');
}

async function testSealedRunWrongKey() {
  console.log('2. Wrong passphrase → DecryptionFailed, no execution...');
  const dek = generateDek();
  const sealed = await sealArtifacts(dek, {
    programJson: JSON.stringify(PLAIN_PROGRAM),
    inputsValues: PLAIN_PROGRAM.inputs.values,
    dbPlaintext: null,
  });
  const grant = await createPassphraseGrant(PASSPHRASE, dek);
  const wrongProvider = createPassphraseKeyProvider('wrong_passphrase_entirely');

  const result = await runSealedProgram({
    grant,
    keyProvider: wrongProvider,
    program: sealed.program,
    inputs: sealed.inputs,
  });

  assert.strictEqual(result.ok, false);
  assert.ok(result.output.includes('DecryptionFailed'), result.output);
  assert.ok(!result.output.includes(PASSPHRASE), 'passphrase must not leak');
  assert.ok(!result.output.includes('completed'));
  console.log('   OK');
}

async function testFencAtLoadRejected() {
  console.log('3. fenc program rejected at VM decode (DecryptionFailed)...');
  const dek = generateDek();
  const env = await encryptEnvelope(dek, 'program', JSON.stringify(PLAIN_PROGRAM));
  const decoded = decodeProgram(JSON.stringify(env));
  assert.strictEqual(decoded.constructor.name, 'Left');
  assert.ok(decoded.value0.includes('DecryptionFailed'), decoded.value0);
  console.log('   OK');
}

async function testDekFileTwin() {
  console.log('4. DEK commit/load file matches plaintext twin hash...');
  const dbFile = '.finvm.db';
  try { await fs.unlink(dbFile); } catch {}

  const dek = generateDek();
  const plain = new FinVMDatabase();
  plain.insert('accounts', { owner: 'alice', balance: 42 });
  const plainHash = plain.hashTable('accounts');

  const enc = new FinVMDatabase();
  await enc.setDEK(dek);
  enc.insert('accounts', { owner: 'alice', balance: 42 });
  await enc.commit();

  const file = await fs.readFile(dbFile, 'utf8');
  assert.ok(file.includes('"fenc"'), 'file must be fenc ciphertext');
  assert.ok(!file.includes('alice'), 'file must not contain plaintext');

  const loaded = new FinVMDatabase();
  await loaded.setDEK(dek);
  await loaded.load();
  assert.strictEqual(loaded.hashTable('accounts'), plainHash, 'hash matches plaintext twin');

  try { await fs.unlink(dbFile); } catch {}
  console.log('   OK');
}

async function run() {
  console.log('Sealed E2E tests\n');
  await testSealedRunE2E();
  await testSealedRunWrongKey();
  await testFencAtLoadRejected();
  await testDekFileTwin();
  console.log('\nSealed E2E tests passed!');
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
