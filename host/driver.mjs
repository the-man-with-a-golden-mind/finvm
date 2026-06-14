// FinVM host effect driver.
//
// The VM core is pure: a run emits effect *intents* into its outbox and reads
// effect *results* from `input`. This driver performs the intents with real I/O,
// feeds results back, and records (intent,result) pairs to a JOURNAL so a run can
// be replayed deterministically with zero I/O.
//
// CONTRACT (see docs/EFFECTS.md):
//  - An intent is { type_, payload }. `payload` is a VRecord that MUST contain a
//    string `key` field (the correlation key = the `input` path where the program
//    reads the result via LOAD_INPUT/LOAD_CONTEXT). Remaining fields are args.
//  - The driver dedups by `key` (an intent whose key is already fulfilled is not
//    re-performed) and carries `state` forward between iterations, so the program
//    is re-entrant across the request/resume loop.
//
// Determinism: per-instruction execution stays in the pure VM (runEffectStep).
// Only this driver is effectful. Replay reproduces value+events+state with no I/O.

import { runEffectStep } from "../dist/finvm-api.js";

const MAX_ITERS = 10000; // safety bound on request/resume rounds

// ---- tagless Value <-> plain JS ----------------------------------------
export function valueToJs(v) {
  if (v === null || v === undefined) return null;
  if (typeof v !== "object") return v;
  if ("bool" in v) return v.bool;
  if ("int" in v) { const n = Number(v.int); return Number.isSafeInteger(n) ? n : BigInt(v.int); }
  if ("string" in v) return v.string;
  if ("symbol" in v) return v.symbol;
  if ("bytes" in v) return v.bytes;
  if ("list" in v) return v.list.map(valueToJs);
  if ("record" in v) { const o = {}; for (const k of Object.keys(v.record)) o[k] = valueToJs(v.record[k]); return o; }
  if ("map" in v) { const o = {}; for (const e of v.map) o[valueToJs(e.key)] = valueToJs(e.value); return o; }
  if ("variant" in v) return { tag: v.variant.tag, payload: valueToJs(v.variant.payload) };
  return v; // fixed/rational/process/etc. pass through unchanged
}

export function jsToValue(x) {
  if (x === null || x === undefined) return null; // VUnit
  if (typeof x === "boolean") return { bool: x };
  if (typeof x === "bigint") return { int: x.toString() };
  if (typeof x === "number") return Number.isInteger(x) ? { int: String(x) } : { string: String(x) };
  if (typeof x === "string") return { string: x };
  if (Array.isArray(x)) return { list: x.map(jsToValue) };
  if (typeof x === "object") {
    if ("tag" in x && "payload" in x) return { variant: { tag: x.tag, payload: jsToValue(x.payload) } };
    const rec = {}; for (const k of Object.keys(x)) rec[k] = jsToValue(x[k]); return { record: rec };
  }
  return { string: String(x) };
}

function correlationKey(intent, payloadJs) {
  if (payloadJs === null || typeof payloadJs !== "object" || typeof payloadJs.key !== "string") {
    throw new Error(`effect intent '${intent.type_}' payload must be a record with a string 'key' field`);
  }
  return payloadJs.key;
}

function step(programSource, inputAccum, stateAccum) {
  // runEffectStep is a curried PureScript function: call f(a)(b).
  const out = JSON.parse(runEffectStep(programSource)(JSON.stringify({ input: inputAccum, state: stateAccum })));
  if (out.status !== "completed") {
    const e = new Error(`VM ${out.status}: ${out.error ?? "unknown"}`);
    e.vmStatus = out.status;
    throw e;
  }
  // attach decoded payloads + dedup against already-fulfilled keys
  out._intents = out.outbox.map((i) => ({ type_: i.type_, payload: i.payload, payloadJs: valueToJs(i.payload) }));
  return out;
}

function eventsToJs(out) {
  return out.events.map((e) => ({ type_: e.type_, payload: valueToJs(e.payload) }));
}

// ---- LIVE run: perform real effects, record a journal -------------------
// handlers: { [type_]: async (payloadJs) => result }
// returns { value, events, journal, state }
export async function runLive(programSource, { handlers = {}, input = {}, state = {}, journal = [] } = {}) {
  const inputAccum = { ...input };
  let stateAccum = { ...state };
  const jrnl = [...journal];
  let last;
  for (let iter = 0; iter < MAX_ITERS; iter++) {
    const out = step(programSource, inputAccum, stateAccum);
    last = out;
    stateAccum = out.state;
    const pending = out._intents.filter((i) => !(correlationKey(i, i.payloadJs) in inputAccum));
    if (pending.length === 0) break;
    // Perform concurrently; write results back IN REQUEST ORDER for deterministic replay.
    const results = await Promise.all(pending.map((i) => {
      const h = handlers[i.type_];
      if (!h) return Promise.reject(new Error(`No handler for effect type: ${i.type_}`));
      return Promise.resolve(h(i.payloadJs));
    }));
    for (let k = 0; k < pending.length; k++) {
      const i = pending[k];
      const key = correlationKey(i, i.payloadJs);
      const rv = jsToValue(results[k]);
      inputAccum[key] = rv;
      jrnl.push({ type_: i.type_, key, payload: i.payload, result: rv });
    }
    if (iter === MAX_ITERS - 1) throw new Error("effect driver exceeded MAX_ITERS (non-converging effect loop)");
  }
  return { value: valueToJs(last.result), events: eventsToJs(last), journal: jrnl, state: stateAccum };
}

// ---- REPLAY run: no I/O, return journaled results in order --------------
// Synchronous and pure: same journal => identical value, events, state.
// returns { value, events, state }
export function runReplay(programSource, journal, { input = {}, state = {} } = {}) {
  const inputAccum = { ...input };
  let stateAccum = { ...state };
  let qi = 0;
  let last;
  for (let iter = 0; iter < MAX_ITERS; iter++) {
    const out = step(programSource, inputAccum, stateAccum);
    last = out;
    stateAccum = out.state;
    const pending = out._intents.filter((i) => !(correlationKey(i, i.payloadJs) in inputAccum));
    if (pending.length === 0) break;
    for (const i of pending) {
      const key = correlationKey(i, i.payloadJs);
      const entry = journal[qi++];
      if (!entry) throw new Error(`journal exhausted: no recorded result for effect '${i.type_}' key '${key}'`);
      if (entry.key !== key || entry.type_ !== i.type_) {
        throw new Error(`journal mismatch at ${qi - 1}: expected ${i.type_}/${key}, journal has ${entry.type_}/${entry.key}`);
      }
      inputAccum[key] = entry.result; // already a tagless Value
    }
  }
  return { value: valueToJs(last.result), events: eventsToJs(last), state: stateAccum };
}
