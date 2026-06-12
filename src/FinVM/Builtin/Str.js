// Pure, deterministic string primitives for the str.* builtins.
// All operate on UTF-16 code units (native JS string semantics). No clock, no
// RNG, no locale-dependent behavior: toUpperCase/toLowerCase use the ECMAScript
// Unicode default case mapping, which is locale-independent.

export const strLength = (s) => s.length;

export const strConcat = (a) => (b) => a + b;

// Clamp start/len to >= 0, then take `len` code units starting at `start`.
export const strSlice = (start) => (len) => (s) => {
  const st = Math.max(0, start);
  const ln = Math.max(0, len);
  return s.slice(st, st + ln);
};

export const strIndexOf = (s) => (needle) => s.indexOf(needle);

export const strSplit = (s) => (sep) => s.split(sep);

export const strToUpper = (s) => s.toUpperCase();

export const strToLower = (s) => s.toLowerCase();

export const strTrim = (s) => s.trim();

export const strReplaceAll = (s) => (from) => (to) => s.replaceAll(from, to);

// Strict decimal-integer recognizer: optional '-', then one or more digits,
// nothing else. The actual numeric value is parsed by the PureScript side.
export const strIsDecimalInt = (s) => /^-?[0-9]+$/.test(s);
