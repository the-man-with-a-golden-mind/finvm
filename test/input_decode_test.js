import assert from 'node:assert';
import { decodeProgram } from '../src/FinVM/FFI/SecureClient.js';

function isRight(e) {
  return e != null && e.constructor?.name === 'Right';
}

function isLeft(e) {
  return e != null && e.constructor?.name === 'Left';
}

const PROGRAM_WITH_INPUTS = JSON.stringify({
  version: '1.0',
  entrypoint: 'main',
  constants: [],
  functions: {
    main: {
      registerCount: 8,
      instructions: [
        ['CALL_BUILTIN', 1, 'input.get@1', [2]],
        ['RETURN', 1],
      ],
    },
  },
  inputs: {
    schema: [
      { name: 'amount', type: 'Int', required: true },
      { name: 'label', type: 'String', required: false },
    ],
    values: {
      amount: { int: '100' },
      label: { string: 'test' },
    },
  },
});

function testInputDecode() {
  console.log('1. inputs.schema + values decode...');
  const result = decodeProgram(PROGRAM_WITH_INPUTS);
  assert.ok(isRight(result), 'Should decode successfully');
  console.log('   OK');
}

function testInputValidationFailure() {
  console.log('2. InputValidation on type mismatch...');
  const bad = JSON.stringify({
    version: '1.0',
    entrypoint: 'main',
    constants: [],
    functions: { main: { registerCount: 4, instructions: [['RETURN', 0]] } },
    inputs: {
      schema: [{ name: 'x', type: 'Int', required: true }],
      values: { x: { string: 'not an int' } },
    },
  });
  const result = decodeProgram(bad);
  assert.ok(isLeft(result), 'Should fail validation');
  console.log('   OK');
}

function testEncryptedValuesPlaceholder() {
  console.log('3. Encrypted inputs.values rejected at decode...');
  const sealed = JSON.stringify({
    version: '1.0',
    entrypoint: 'main',
    constants: [],
    functions: { main: { registerCount: 4, instructions: [['RETURN', 0]] } },
    inputs: {
      schema: [{ name: 'x', type: 'Int', required: true }],
      values: { fenc: 1, target: 'inputs', cipher: 'aes-256-gcm', iv: 'abc', ct: 'def', aad: 'finvm:inputs' },
    },
  });
  const result = decodeProgram(sealed);
  assert.ok(isLeft(result));
  assert.ok(result.value0.includes('DecryptionFailed'), result.value0);
  console.log('   OK');
}

function testDecryptedValuesOverride() {
  console.log('4. decryptedValues override from SecureLoader...');
  const sealed = JSON.stringify({
    version: '1.0',
    entrypoint: 'main',
    constants: [],
    functions: { main: { registerCount: 4, instructions: [['RETURN', 0]] } },
    inputs: {
      schema: [{ name: 'x', type: 'Int', required: true }],
      values: { fenc: 1, target: 'inputs', cipher: 'aes-256-gcm', iv: 'abc', ct: 'def', aad: 'finvm:inputs' },
    },
  });
  const decrypted = JSON.stringify({ x: { int: '99' } });
  const result = decodeProgram(sealed, decrypted);
  assert.ok(isRight(result));
  console.log('   OK');
}

function run() {
  console.log('Input decode integration tests\n');
  testInputDecode();
  testInputValidationFailure();
  testEncryptedValuesPlaceholder();
  testDecryptedValuesOverride();
  console.log('\nAll input decode tests passed!');
}

run();
