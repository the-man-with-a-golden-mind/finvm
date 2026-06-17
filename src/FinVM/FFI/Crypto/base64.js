// Base64 helpers for envelope wire format (no node:buffer dependency).

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function bytesToBase64(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    const n = (b0 << 16) | (b1 << 8) | b2;
    out += B64[(n >> 18) & 63];
    out += B64[(n >> 12) & 63];
    out += i + 1 < bytes.length ? B64[(n >> 6) & 63] : '=';
    out += i + 2 < bytes.length ? B64[n & 63] : '=';
  }
  return out;
}

export function base64ToBytes(b64) {
  const clean = b64.replace(/[^A-Za-z0-9+/=]/g, '');
  const len = clean.length;
  const out = new Uint8Array(Math.floor(len * 3 / 4) - (clean.endsWith('==') ? 2 : clean.endsWith('=') ? 1 : 0));
  let j = 0;
  for (let i = 0; i < len; i += 4) {
    const c0 = B64.indexOf(clean[i]);
    const c1 = B64.indexOf(clean[i + 1]);
    const c2 = clean[i + 2] === '=' ? 0 : B64.indexOf(clean[i + 2]);
    const c3 = clean[i + 3] === '=' ? 0 : B64.indexOf(clean[i + 3]);
    const n = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
    out[j++] = (n >> 16) & 255;
    if (clean[i + 2] !== '=') out[j++] = (n >> 8) & 255;
    if (clean[i + 3] !== '=') out[j++] = n & 255;
  }
  return out;
}
