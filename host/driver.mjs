// FinVM host effect driver.
//
// Snapshot/resume model:
//  - runEffectStart(program, overrides) runs to quiescence and returns:
//      { status, snapshot, pending, events, result, state }
//  - when status === "suspended", perform all pending effects, then
//    runEffectResume(program, snapshot, deliveries) to continue from that
//    exact machine state (no whole-program re-run).
//
// This file performs real I/O for live runs and records a JOURNAL so the same
// execution can be replayed with zero I/O.
//
// CONTRACT (see docs/EFFECTS.md):
//  - pending entries are in request order:
//      { pid, key, type_, payload }
//  - live runs may perform handlers concurrently (Promise.all), but deliveries
//    MUST be sent in pending order for deterministic replay.
//  - replay uses the recorded journal entries (pid,key,type_,payload,result)
//    rather than performing effects.

import { runEffectStart, runEffectResume } from "../dist/finvm-api.js";

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

function normalizePending(entry) {
  if (!entry || typeof entry !== "object") {
    throw new Error("invalid pending entry: expected object");
  }
  const payloadJs = valueToJs(entry.payload);
  const normalized = { ...entry };
  if (typeof normalized.kind !== "string" || normalized.kind.length === 0) {
    normalized.kind =
      typeof normalized.key === "string" && normalized.key.length > 0
        ? "await_reply"
        : "transport";
  }
  if (normalized.kind !== "await_reply" && normalized.kind !== "transport") {
    throw new Error(`invalid pending entry: unknown kind '${normalized.kind}'`);
  }
  if (typeof normalized.pid !== "string" || normalized.pid.length === 0) {
    normalized.pid =
      payloadJs && typeof payloadJs === "object" && typeof payloadJs.pid === "string"
        ? payloadJs.pid
        : "main";
  }
  if (normalized.kind === "await_reply" && (typeof normalized.key !== "string" || normalized.key.length === 0)) {
    throw new Error("invalid pending entry: await_reply requires key");
  }
  if (normalized.kind === "transport" && (typeof normalized.key !== "string" || normalized.key.length === 0)) {
    normalized.key = null;
  }
  if (typeof normalized.type_ !== "string" || normalized.type_.length === 0) {
    throw new Error("invalid pending entry: missing type_");
  }
  return normalized;
}

function parseVmOutput(raw) {
  let out;
  try {
    out = JSON.parse(raw);
  } catch (err) {
    throw new Error(`invalid VM JSON output: ${String(err)}`);
  }
  if (!out || typeof out !== "object" || typeof out.status !== "string") {
    throw new Error("invalid VM output shape");
  }
  if (out.status === "error" || out.status === "failed") {
    const e = new Error(`VM ${out.status}: ${out.error ?? "unknown"}`);
    e.vmStatus = out.status;
    throw e;
  }
  return out;
}

function start(programSource, inputAccum, stateAccum) {
  // runEffectStart is curried: runEffectStart(program)(overridesJson)
  const raw = runEffectStart(programSource)(JSON.stringify({ input: inputAccum, state: stateAccum }));
  return parseVmOutput(raw);
}

function resume(programSource, snapshotJson, deliveries) {
  // runEffectResume is curried: runEffectResume(program)(snapshot)(deliveriesJson)
  const raw = runEffectResume(programSource)(snapshotJson)(JSON.stringify(deliveries));
  return parseVmOutput(raw);
}

function eventsToJs(out) {
  const events = Array.isArray(out.events) ? out.events : [];
  return events.map((e) => ({ type_: e.type_, payload: valueToJs(e.payload) }));
}

// ---- LIVE run: perform real effects, record a journal -------------------
// handlers: { [type_]: async (payloadJs) => result }
// returns { value, events, journal, state }
export async function runLive(programSource, { handlers = {}, input = {}, state = {}, journal = [] } = {}) {
  const inputAccum = { ...input }; // initial seed for runEffectStart only
  const stateAccum = { ...state }; // initial seed for runEffectStart only
  const jrnl = [...journal];
  let out = start(programSource, inputAccum, stateAccum);

  for (let iter = 0; iter < MAX_ITERS; iter++) {
    if (out.status === "completed") {
      return { value: valueToJs(out.result), events: eventsToJs(out), journal: jrnl, state: out.state };
    }
    if (out.status !== "suspended") {
      throw new Error(`VM ${out.status}: expected suspended/completed`);
    }

    const pendingRaw = Array.isArray(out.pending) ? out.pending : [];
    const pending = pendingRaw.map(normalizePending);
    if (pending.length === 0) {
      throw new Error("VM returned status 'suspended' with no pending effects");
    }

    // Perform concurrently; build deliveries IN REQUEST ORDER.
    const results = await Promise.all(
      pending.map((p) => {
        const h = handlers[p.type_];
        if (!h) return Promise.reject(new Error(`No handler for effect type: ${p.type_}`));
        const payloadJs = valueToJs(p.payload);
        // Keep key available to handlers for backward compatibility.
        const payloadWithKey =
          payloadJs && typeof payloadJs === "object" && !Array.isArray(payloadJs)
            ? { key: p.key, ...payloadJs }
            : payloadJs;
        return Promise.resolve(h(payloadWithKey, { pid: p.pid, key: p.key, type_: p.type_ }));
      })
    );

    const deliveries = [];
    for (let k = 0; k < pending.length; k++) {
      const p = pending[k];
      const rv = jsToValue(results[k]);
      if (p.kind === "await_reply") {
        deliveries.push({ pid: p.pid, key: p.key, result: rv });
      }
      jrnl.push({ kind: p.kind, pid: p.pid, key: p.key, type_: p.type_, payload: p.payload, result: rv });
    }

    const snapshotJson = JSON.stringify(out.snapshot);
    out = resume(programSource, snapshotJson, deliveries);

    if (iter === MAX_ITERS - 1) throw new Error("effect driver exceeded MAX_ITERS (non-converging effect loop)");
  }
  throw new Error("effect driver exceeded MAX_ITERS (non-converging effect loop)");
}

// ---- REPLAY run: no I/O, return journaled results in order --------------
// Synchronous and pure: same journal => identical value, events, state.
// returns { value, events, state }
export function runReplay(programSource, journal, { input = {}, state = {} } = {}) {
  const inputAccum = { ...input }; // initial seed for runEffectStart only
  const stateAccum = { ...state }; // initial seed for runEffectStart only
  let qi = 0;
  let out = start(programSource, inputAccum, stateAccum);

  for (let iter = 0; iter < MAX_ITERS; iter++) {
    if (out.status === "completed") {
      return { value: valueToJs(out.result), events: eventsToJs(out), state: out.state };
    }
    if (out.status !== "suspended") {
      throw new Error(`VM ${out.status}: expected suspended/completed`);
    }

    const pendingRaw = Array.isArray(out.pending) ? out.pending : [];
    const pending = pendingRaw.map(normalizePending);
    if (pending.length === 0) {
      throw new Error("VM returned status 'suspended' with no pending effects");
    }

    const deliveries = [];
    for (const p of pending) {
      const entry = journal[qi++];
      if (!entry) throw new Error(`journal exhausted: no recorded result for effect '${p.type_}' key '${p.key}'`);
      const expectedKey = p.kind === "await_reply" ? p.key : null;
      const actualKey = entry.key ?? null;
      const expectedKind = p.kind;
      const actualKind = entry.kind ?? (actualKey !== null ? "await_reply" : "transport");
      if (entry.pid !== p.pid || actualKey !== expectedKey || entry.type_ !== p.type_ || actualKind !== expectedKind) {
        throw new Error(
          `journal mismatch at ${qi - 1}: expected ${p.kind}/${p.pid}/${p.type_}/${p.key}, ` +
          `journal has ${actualKind}/${entry.pid}/${entry.type_}/${entry.key}`
        );
      }
      if (p.kind === "await_reply") {
        deliveries.push({ pid: p.pid, key: p.key, result: entry.result }); // already tagless Value
      }
    }

    const snapshotJson = JSON.stringify(out.snapshot);
    out = resume(programSource, snapshotJson, deliveries);

    if (iter === MAX_ITERS - 1) throw new Error("effect replay exceeded MAX_ITERS (non-converging effect loop)");
  }
  throw new Error("effect replay exceeded MAX_ITERS (non-converging effect loop)");
}
