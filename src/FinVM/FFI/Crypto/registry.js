// Extensible crypto suite registries — register new algorithms without editing callers.

const ciphers = new Map();
const kdfs = new Map();
const wraps = new Map();

export function registerCipher(id, impl) {
  ciphers.set(id, impl);
}

export function registerKdf(id, impl) {
  kdfs.set(id, impl);
}

export function registerWrap(id, impl) {
  wraps.set(id, impl);
}

export function getCipher(id) {
  const impl = ciphers.get(id);
  if (!impl) throw new Error(`Unknown cipher: ${id}`);
  return impl;
}

export function getKdf(id) {
  const impl = kdfs.get(id);
  if (!impl) throw new Error(`Unknown KDF: ${id}`);
  return impl;
}

export function getWrap(id) {
  const impl = wraps.get(id);
  if (!impl) throw new Error(`Unknown wrap: ${id}`);
  return impl;
}

export function listCiphers() { return [...ciphers.keys()]; }
export function listKdfs() { return [...kdfs.keys()]; }
export function listWraps() { return [...wraps.keys()]; }
