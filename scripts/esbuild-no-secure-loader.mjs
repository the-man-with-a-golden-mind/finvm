// esbuild plugin: server bundles must not include SecureLoader / decrypt path.

export default function noSecureLoaderPlugin() {
  return {
    name: 'no-secure-loader',
    setup(build) {
      const isServer = build.initialOptions.platform === 'node';
      if (!isServer) return;

      const block = (path) =>
        /[/\\]FinVM[/\\]FFI[/\\](SecureLoader|SecureClient|KeyProvider)\.js$/.test(path.replace(/\\/g, '/'))
        || /[/\\]FinVM[/\\]FFI[/\\]Crypto[/\\]/.test(path.replace(/\\/g, '/'));

      build.onLoad({ filter: /.*/ }, (args) => {
        if (block(args.path)) {
          return {
            errors: [{
              text: 'FINVM_SECURE_CLIENT_ONLY: SecureLoader/crypto decrypt modules cannot be bundled in server builds',
            }],
          };
        }
        return null;
      });
    },
  };
}
