import assert from 'node:assert';
import esbuild from 'esbuild';
import noSecureLoaderPlugin from '../scripts/esbuild-no-secure-loader.mjs';

async function testServerBundleBlocksSecureLoader() {
  console.log('1. Server bundle must fail when importing SecureLoader...');
  let failed = false;
  try {
    await esbuild.build({
      entryPoints: ['test/fixtures/server-imports-secureloader.js'],
      platform: 'node',
      bundle: true,
      write: false,
      plugins: [noSecureLoaderPlugin()],
      logLevel: 'silent',
    });
  } catch (e) {
    failed = true;
    const msg = e.errors?.map((x) => x.text).join('\n') ?? String(e);
    assert.ok(msg.includes('FINVM_SECURE_CLIENT_ONLY'), msg);
  }
  assert.ok(failed, 'esbuild must fail for SecureLoader in server bundle');
  console.log('   OK');
}

async function testApiBundleHasNoDecrypt() {
  console.log('2. dist/finvm-api.js must not contain decrypt path...');
  const { readFileSync, existsSync } = await import('node:fs');
  if (!existsSync('dist/finvm-api.js')) {
    console.log('   SKIP (run npm run build first)');
    return;
  }
  const src = readFileSync('dist/finvm-api.js', 'utf8');
  assert.ok(!src.includes('loadSecure'), 'no loadSecure');
  assert.ok(!src.includes('decryptEnvelope'), 'no decryptEnvelope');
  assert.ok(!src.includes('unwrapDek'), 'no unwrapDek');
  assert.ok(!src.includes('FinVM/FFI/Crypto'), 'no crypto FFI path');
  console.log('   OK');
}

async function run() {
  console.log('Server bundle guard tests\n');
  await testServerBundleBlocksSecureLoader();
  await testApiBundleHasNoDecrypt();
  console.log('\nServer bundle tests passed!');
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
