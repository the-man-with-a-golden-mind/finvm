import esbuild from 'esbuild';
import noSecureLoaderPlugin from './esbuild-no-secure-loader.mjs';

const common = {
  bundle: true,
  format: 'esm',
  external: ['big-integer'],
  plugins: [noSecureLoaderPlugin()],
};

await esbuild.build({
  ...common,
  entryPoints: ['output/Main/index.js'],
  platform: 'node',
  outfile: 'dist/finvm-core.js',
});

await esbuild.build({
  ...common,
  entryPoints: ['output/FinVM.Encoding.Json/index.js'],
  platform: 'node',
  outfile: 'dist/finvm-api.js',
});

await esbuild.build({
  entryPoints: ['output/FinVM.Encoding.Json/index.js'],
  platform: 'browser',
  bundle: true,
  outfile: 'dist/finvm-api.browser.js',
  format: 'esm',
  external: ['node:fs/promises', 'big-integer'],
});

await esbuild.build({
  entryPoints: ['host/secure.mjs'],
  platform: 'browser',
  bundle: true,
  outfile: 'dist/finvm-secure.browser.js',
  format: 'esm',
  external: ['node:fs/promises'],
});

console.log('Bundles written to dist/');
