import assert from 'node:assert';
import 'fake-indexeddb/auto';
import {
  generateDek,
  sealArtifacts,
  createPassphraseGrant,
  createPassphraseKeyProvider,
} from '../host/secure.mjs';
import { runLiveSecure } from '../host/secureDriver.mjs';
import { runSealedProgram, assertNoSecrets } from '../src/FinVM/FFI/SecureClient.js';
import { FinVMDatabase } from '../src/FinVM/FFI/Database.js';
import { createIndexedDbPersistence } from '../src/FinVM/FFI/db-persistence.js';
import { runReplay, valueToJs } from '../host/driver.mjs';
import { runEffectStart } from '../dist/finvm-api.js';

const PASSPHRASE = 'secure_effects_passphrase_do_not_log';

const DB_EFFECT_PROGRAM = JSON.stringify({
  version: '1.0',
  entrypoint: 'main',
  constants: [
    { string: 'kIns' },
    { string: 'kCommit' },
    { string: 'items' },
    { int: '7' },
  ],
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
        ['PROC_RECEIVE', 9],
        ['VARIANT_PAYLOAD', 10, 9],
        ['RECORD_GET', 11, 10, 'value'],
        ['RETURN', 11],
      ],
    },
  },
});

const OUTPUT_SAVE_PROGRAM = JSON.stringify({
  version: '1.0',
  entrypoint: 'main',
  constants: [{ string: 'kOut' }, { string: 'done' }],
  functions: {
    main: {
      registerCount: 12,
      instructions: [
        ['RECORD_NEW', 0],
        ['LOAD_CONST', 1, 0], ['RECORD_SET', 0, 0, 'key', 1],
        ['LOAD_CONST', 2, 1], ['RECORD_SET', 0, 0, 'payload', 2],
        ['EFFECT_NEW', 3, 'output.save', 0],
        ['EFFECT_AWAIT', 3],
        ['PROC_RECEIVE', 4],
        ['VARIANT_PAYLOAD', 5, 4],
        ['RECORD_GET', 6, 5, 'value'],
        ['RETURN', 6],
      ],
    },
  },
});

function journalEntry(journal, type_) {
  return journal.find((e) => e.type_ === type_);
}

async function testRunLiveSecureDbCommitEgress() {
  console.log('1. runLiveSecure db.insert + db.commit → ciphertext-only journal...');
  const dek = generateDek();
  const live = await runLiveSecure(dek, DB_EFFECT_PROGRAM);
  const commitEntry = journalEntry(live.journal, 'db.commit');
  assert.ok(commitEntry, 'db.commit must be journaled');
  const commitJs = valueToJs(commitEntry.result);
  const resultText = typeof commitJs === 'string' ? commitJs : JSON.stringify(commitJs);
  assert.ok(resultText.includes('"fenc"'), 'db.commit result must be fenc ciphertext');
  assert.ok(resultText.includes('"target":"db"') || resultText.includes('"target": "db"'));
  assert.ok(!resultText.includes('"n"'), 'journal must not contain plaintext record fields');
  assert.ok(live.egress?.target === 'output', 'final egress uses output target');
  assertNoSecrets(JSON.stringify(live.journal), [dek]);
  assertNoSecrets(JSON.stringify(live.egress), [dek]);
  console.log('   OK');
}

async function testRunLiveSecureOutputSaveEgress() {
  console.log('2. runLiveSecure output.save → ciphertext-only journal...');
  const dek = generateDek();
  const live = await runLiveSecure(dek, OUTPUT_SAVE_PROGRAM);
  const saveEntry = journalEntry(live.journal, 'output.save');
  assert.ok(saveEntry, 'output.save must be journaled');
  const saveJs = valueToJs(saveEntry.result);
  const resultText = typeof saveJs === 'string' ? saveJs : JSON.stringify(saveJs);
  assert.ok(resultText.includes('"fenc"'), 'output.save result must be fenc ciphertext');
  assert.ok(resultText.includes('"target":"output"') || resultText.includes('"target": "output"'));
  assert.ok(!resultText.includes('done'), 'output.save must not leak plaintext payload');
  console.log('   OK');
}

async function testSealedProgramLiveDbPath() {
  console.log('3. runSealedProgram with sealed DB uses live effect path...');
  const dek = generateDek();
  const dbPlain = new FinVMDatabase();
  dbPlain.insert('seed', { seeded: true });
  const dbPlaintext = JSON.stringify({
    sequence: 1,
    tables: [['seed', Array.from(dbPlain.tables.get('seed').entries())]],
  });
  const sealed = await sealArtifacts(dek, {
    programJson: DB_EFFECT_PROGRAM,
    inputsValues: null,
    dbPlaintext,
  });
  const grant = await createPassphraseGrant(PASSPHRASE, dek);
  const keyProvider = createPassphraseKeyProvider(PASSPHRASE);

  const result = await runSealedProgram({
    grant,
    keyProvider,
    program: sealed.program,
    db: sealed.db,
  });

  assert.strictEqual(result.ok, true, result.output);
  assert.ok(result.egress?.target === 'output');
  const commitEntry = journalEntry(result.journal, 'db.commit');
  assert.ok(commitEntry, 'sealed live run must journal db.commit');
  assertNoSecrets(JSON.stringify(result.journal), [PASSPHRASE, dek]);
  assertNoSecrets(JSON.stringify(result.egress), [PASSPHRASE, dek]);
  console.log('   OK');
}

async function testIndexedDbPersistence() {
  console.log('4. IndexedDB persistence round-trip (fake-indexeddb)...');
  const dek = generateDek();
  const persistence = createIndexedDbPersistence({
    dbName: 'finvm_test_db',
    storeName: 'kv',
    key: 'bundle',
  });
  const db = new FinVMDatabase({ persistence });
  await db.setDEK(dek);
  db.insert('accounts', { owner: 'alice', balance: 100 });
  const hashBefore = db.hashTable('accounts');
  await db.commit();

  const db2 = new FinVMDatabase({ persistence });
  await db2.setDEK(dek);
  await db2.load();
  assert.strictEqual(db2.hashTable('accounts'), hashBefore);
  const file = await persistence.read();
  assert.ok(file.includes('"fenc"'), 'IndexedDB blob must be fenc ciphertext');
  assert.ok(!file.includes('alice'), 'IndexedDB blob must not contain plaintext');
  console.log('   OK');
}

async function testReplaySnapshotNoSecrets() {
  console.log('5. replay journal/snapshot paths never contain passphrase...');
  const dek = generateDek();
  const live = await runLiveSecure(dek, OUTPUT_SAVE_PROGRAM);
  const replay = runReplay(OUTPUT_SAVE_PROGRAM, live.journal);
  assert.deepStrictEqual(replay.value, live.value);
  const startOut = JSON.parse(runEffectStart(OUTPUT_SAVE_PROGRAM)('{}'));
  assert.ok(startOut.snapshot, 'effect start must expose snapshot');
  assertNoSecrets(JSON.stringify(startOut.snapshot), [PASSPHRASE, dek]);
  assertNoSecrets(JSON.stringify(live.journal), [PASSPHRASE, dek]);
  console.log('   OK');
}

async function run() {
  console.log('Secure effects & persistence tests\n');
  await testRunLiveSecureDbCommitEgress();
  await testRunLiveSecureOutputSaveEgress();
  await testSealedProgramLiveDbPath();
  await testIndexedDbPersistence();
  await testReplaySnapshotNoSecrets();
  console.log('\nSecure effects tests passed!');
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
