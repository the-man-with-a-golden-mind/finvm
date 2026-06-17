import assert from 'node:assert';
import {
  bootstrapCrypto,
  generateDek,
  encryptEnvelope,
  decryptEnvelope,
  DecryptionFailed,
} from '../src/FinVM/FFI/Crypto/index.js';
import { importAesKey } from '../src/FinVM/FFI/Crypto/aes-256-gcm.js';
import { argon2idDeriveRaw, ARGON2_MIN_MEMORY, ARGON2_MIN_ITERATIONS } from '../src/FinVM/FFI/Crypto/argon2id.js';
import { pbkdf2Sha256Raw, PBKDF2_MIN_ITERATIONS } from '../src/FinVM/FFI/Crypto/pbkdf2-sha256.js';
import {
  createPassphraseKeyProvider,
  createWalletKeyProvider,
  createPassphraseGrant,
  createWalletGrant,
} from '../src/FinVM/FFI/KeyProvider.js';
import { loadSecure, redactSecrets, sealArtifacts } from '../src/FinVM/FFI/SecureLoader.js';
import { unwrapDek } from '../src/FinVM/FFI/Crypto/dek.js';
import { privateKeyFromHex, pubKeyFromPrivate } from '../src/FinVM/FFI/Crypto/ecies-secp256k1.js';
import { FinVMDatabase } from '../src/FinVM/FFI/Database.js';
import * as fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createEncryptedDbStorage, sealOutputPayload } from '../host/encryptedStorage.mjs';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');

bootstrapCrypto();

const PROGRAM = JSON.stringify({
  version: '1.0',
  entrypoint: 'main',
  constants: [{ int: '0' }],
  functions: {
    main: {
      registerCount: 4,
      instructions: [
        ['LOAD_CONST', 0, 0],
        ['RETURN', 0],
      ],
    },
  },
  inputs: {
    schema: [{ name: 'x', type: 'Int', required: true }],
    values: { x: { int: '42' } },
  },
});

const INPUTS_VALUES = { x: { int: '42' } };
const DB_PLAINTEXT = JSON.stringify({ sequence: 1, tables: [['t', [['rec0', { id: 'rec0', timestamp: 0, content: { v: 1 } }]]]] });

async function testDekRoundTrip() {
  console.log('1. DEK round-trip (program/inputs/db)...');
  const dek = generateDek();
  const sealed = await sealArtifacts(dek, {
    programJson: PROGRAM,
    inputsValues: INPUTS_VALUES,
    dbPlaintext: DB_PLAINTEXT,
  });

  const progPt = await decryptEnvelope(dek, sealed.program);
  assert.strictEqual(progPt, PROGRAM);

  const inputsPt = JSON.parse(await decryptEnvelope(dek, sealed.inputs));
  assert.deepStrictEqual(inputsPt, INPUTS_VALUES);

  const dbPt = await decryptEnvelope(dek, sealed.db);
  assert.strictEqual(dbPt, DB_PLAINTEXT);
  console.log('   OK');
}

async function testWrongDek() {
  console.log('2. Wrong DEK / tampered ct / swapped target → DecryptionFailed...');
  const dek = generateDek();
  const wrong = generateDek();
  const env = await encryptEnvelope(dek, 'program', PROGRAM);

  await assert.rejects(() => decryptEnvelope(wrong, env), DecryptionFailed);

  const tampered = { ...env, ct: env.ct.slice(0, -4) + 'AAAA' };
  await assert.rejects(() => decryptEnvelope(dek, tampered), DecryptionFailed);

  const swapped = { ...env, target: 'inputs', aad: 'finvm:inputs' };
  await assert.rejects(() => decryptEnvelope(dek, swapped), DecryptionFailed);
  console.log('   OK');
}

async function testPassphraseUnwrap() {
  console.log('3. Passphrase KEK unwrap...');
  const dek = generateDek();
  const passphrase = 'correct horse battery staple';
  const grant = await createPassphraseGrant(passphrase, dek);
  const provider = createPassphraseKeyProvider(passphrase);
  const loaded = await loadSecure({
    grant,
    keyProvider: provider,
    program: await encryptEnvelope(dek, 'program', PROGRAM),
    inputs: await encryptEnvelope(dek, 'inputs', JSON.stringify(INPUTS_VALUES)),
  });
  assert.ok(loaded.programJson.includes('"main"'));
  assert.deepStrictEqual(loaded.inputsValues, INPUTS_VALUES);

  const wrongProvider = createPassphraseKeyProvider('wrong passphrase entirely');
  const encProgram = await encryptEnvelope(dek, 'program', PROGRAM);
  try {
    await loadSecure({ grant, keyProvider: wrongProvider, program: encProgram });
    assert.fail('should throw');
  } catch (e) {
    assert.ok(e instanceof DecryptionFailed);
    assert.ok(!String(e.message).includes(passphrase), 'passphrase must not appear in error');
  }
  console.log('   OK');
}

async function testWalletEcies() {
  console.log('4. Wallet ECIES unwrap...');
  const dek = generateDek();
  // Deterministic test key (never use in production)
  const privHex = '0x' + '11'.repeat(32);
  const priv = privateKeyFromHex(privHex);
  const grant = await createWalletGrant(privHex, dek);
  const provider = createWalletKeyProvider(privHex);
  const loaded = await loadSecure({
    grant,
    keyProvider: provider,
    program: await encryptEnvelope(dek, 'program', PROGRAM),
  });
  assert.ok(loaded.programJson.includes('"main"'));

  const wrongPriv = '0x' + '22'.repeat(32);
  const wrongProvider = createWalletKeyProvider(wrongPriv);
  const encProgram = await encryptEnvelope(dek, 'program', PROGRAM);
  await assert.rejects(
    () => loadSecure({ grant, keyProvider: wrongProvider, program: encProgram }),
    DecryptionFailed,
  );
  void pubKeyFromPrivate(priv);
  console.log('   OK');
}

async function testEncryptedDbDek() {
  console.log('5. Encrypted DB with DEK (Node file persist)...');
  const dbFile = '.finvm-dek-test.db';
  try { await fs.unlink(dbFile); } catch {}
  const dek = generateDek();
  const db = new FinVMDatabase();
  await db.setDEK(dek);
  db.insert('accounts', { owner: 'alice', balance: 100 });
  const blob = await db.exportEncrypted();
  assert.ok(blob.includes('"fenc"'), 'DEK export must be fenc envelope');
  assert.ok(!blob.includes('alice'), 'No plaintext in export');

  const db2 = new FinVMDatabase();
  await db2.setDEK(dek);
  await db2.importEncrypted(blob);
  const rows = db2.query('accounts', {});
  assert.strictEqual(rows.length, 1);
  assert.strictEqual(rows[0].content.balance, 100);

  // Wrong DEK
  const db3 = new FinVMDatabase();
  await db3.setDEK(generateDek());
  await assert.rejects(() => db3.importEncrypted(blob), DecryptionFailed);
  console.log('   OK');
}

function testSecretsRedaction() {
  console.log('6. Secrets never appear in redacted logs...');
  const secret = 'super_secret_passphrase_xyz';
  const dek = new Uint8Array(32);
  const obj = {
    passphrase: secret,
    dek,
    grant: { ct: 'abc', wrap: 'aesgcm-keywrap' },
    nested: { privateKey: '0xdeadbeef' },
  };
  const redacted = JSON.stringify(redactSecrets(obj));
  assert.ok(!redacted.includes(secret), 'Passphrase must be redacted');
  assert.ok(!redacted.includes('deadbeef'), 'Private key must be redacted');
  assert.ok(redacted.includes('[REDACTED]'), 'Redaction marker present');
  console.log('   OK');
}

async function testCiphertextEgress() {
  console.log('8. Ciphertext-only egress (sealOutputPayload / exportCiphertext)...');
  const dek = generateDek();
  const storage = createEncryptedDbStorage(dek);
  await storage.dbInsert('t', { v: 1 });
  const blob = await storage.exportCiphertext();
  assert.ok(typeof blob === 'string');
  assert.ok(blob.includes('"fenc"'));
  assert.ok(JSON.parse(blob).target === 'db');
  assert.ok(!blob.includes('"v"'), 'db egress must not contain plaintext field names from records');

  const sealed = await sealOutputPayload(dek, { result: 42, state: {} });
  assert.ok(sealed.fenc === 1 && sealed.target === 'output');
  assert.ok(sealed.aad === 'finvm:output');
  assert.ok(sealed.ct.length > 10, 'output sealed');

  const outputPt = JSON.stringify({ answer: 42 });
  const outputEnv = await encryptEnvelope(dek, 'output', outputPt);
  const roundTrip = await decryptEnvelope(dek, outputEnv);
  assert.strictEqual(roundTrip, outputPt);
  console.log('   OK');
}

async function testKdfFloors() {
  console.log('9. KDF parameter floors enforced...');
  const salt = new Uint8Array(16);
  await assert.rejects(
    () => argon2idDeriveRaw('pass', salt, { memorySize: ARGON2_MIN_MEMORY - 1 }),
    /below floor/,
  );
  await assert.rejects(
    () => argon2idDeriveRaw('pass', salt, { iterations: ARGON2_MIN_ITERATIONS - 1 }),
    /below floor/,
  );
  await assert.rejects(
    () => pbkdf2Sha256Raw('pass', salt, PBKDF2_MIN_ITERATIONS - 1),
    /below floor/,
  );
  console.log('   OK');
}

async function testNonExtractableKeys() {
  console.log('10. AES keys imported as non-extractable...');
  const dek = generateDek();
  const key = await importAesKey(dek);
  await assert.rejects(() => globalThis.crypto.subtle.exportKey('raw', key));
  console.log('   OK');
}

async function testEthDecryptAlias() {
  console.log('11. eth-decrypt wrap alias round-trips wallet grants...');
  const dek = generateDek();
  const privHex = '0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const grant = await createWalletGrant(privHex, dek);
  grant.wrap = 'eth-decrypt';
  const provider = createWalletKeyProvider(privHex);
  const unwrapped = await unwrapDek(grant, provider);
  assert.deepStrictEqual(unwrapped, dek);
  console.log('   OK');
}

async function testServerBuildGuard() {
  console.log('7. Server build guard (FINVM_SERVER_BUILD=1)...');
  const { spawnSync } = await import('node:child_process');
  const r = spawnSync(process.execPath, [
    '--input-type=module',
    '-e',
    "import('./src/FinVM/FFI/SecureLoader.js')",
  ], {
    cwd: repoRoot,
    env: { ...process.env, FINVM_SERVER_BUILD: '1' },
    encoding: 'utf8',
  });
  assert.notStrictEqual(r.status, 0, 'SecureLoader must fail in server build');
  assert.ok((r.stderr + r.stdout).includes('FINVM_SECURE_CLIENT_ONLY'), r.stderr);
  console.log('   OK');
}

async function run() {
  console.log('Crypto & SecureLoader Tests\n');
  await testDekRoundTrip();
  await testWrongDek();
  await testPassphraseUnwrap();
  await testWalletEcies();
  await testEncryptedDbDek();
  testSecretsRedaction();
  await testCiphertextEgress();
  await testKdfFloors();
  await testNonExtractableKeys();
  await testEthDecryptAlias();
  await testServerBuildGuard();
  console.log('\nAll crypto tests passed!');
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
