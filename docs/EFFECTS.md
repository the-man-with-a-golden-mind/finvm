# FinVM — Effects: Host Driver, Intent Contract & Journal

The VM core is pure: a run **emits effect intents** into its `outbox` and **reads
effect results** from `input`. It never performs I/O. The **host driver**
(`host/`) performs the intents with real I/O (HTTP, storage, logging), feeds the
results back, and records every `(intent, result)` pair to a **journal** so any run
can be replayed deterministically with zero I/O. See also [VM_SPEC.md](VM_SPEC.md)
(effect opcodes) and [ARCHITECTURE.md](ARCHITECTURE.md).

## 1. The model (in the VM)
- `EFFECT_NEW dst type_ payloadReg` builds `VEffectIntent { type_, payload }`.
- `EFFECT_REQUEST src` pushes an intent onto the machine `outbox`.
- `LOAD_INPUT dst key` / `LOAD_CONTEXT dst key` read a value from `input` (they
  **error** if the key is absent — see re-entrancy below).
- `EVENT_EMIT` appends `VEvent { type_, payload }` to `events` (host-visible log).
- `externalBuiltins` are **pure** host functions (called inline during a step).
  **Effects do NOT go through externalBuiltins** — they go through the
  outbox/intent mechanism so they can be journaled and replayed.

## 2. Intent contract
An intent is `{ type_, payload }`. **`payload` MUST be a `VRecord` containing a
string `key` field** — the *correlation key*, i.e. the `input` path under which the
driver delivers the result and which the program later reads with `LOAD_INPUT`.
Remaining fields are the effect's arguments.

| `type_` | required payload fields (besides `key`) | result delivered to `input[key]` |
|---|---|---|
| `http.get` | `url` (string), optional `headers` | response body (string) |
| `http.post` | `url`, optional `body`, `headers` | response body (string) |
| `sys.log` | `message` (string) | `true` |
| `db.insert` | `table`, `record` | inserted id (string) |
| `db.get` | `table`, `id` | record, or null if absent |
| `db.update` | `table`, `id`, `record` | bool |
| `db.delete` | `table`, `id` | bool |
| `cache.set` | `ns`, `cacheKey`, `value` | bool |
| `cache.get` | `ns`, `cacheKey` | value, or null |
| `cache.delete` | `ns`, `cacheKey` | bool |

> Note: for cache effects the storage key is `cacheKey`, because `key` is reserved
> for the correlation/input slot.

**Unknown `type_`** → the driver rejects cleanly (`No handler for effect type: …`);
it never crashes the VM, and the VM itself raises clean `VMError`s for malformed
intents (e.g. a payload without a string `key`).

## 3. The driver loop (`host/driver.mjs`)
`runEffectStep` (PureScript, pure) runs the program once with injected
`input`/`state` and returns `{ status, result, state, events, outbox }`. The driver:

1. Run the program (pure) with the accumulated `input` and `state`.
2. Take `outbox` intents in **request order**; keep only those whose `key` is not
   already in `input` (**dedup by key** → no double-writes on re-entry).
3. Perform the pending intents (live: handlers; replay: journal) and write each
   result into `input[key]`; carry `state` forward.
4. Repeat until a run yields no new effects, then return the final value/events.

**Re-entrancy.** Because `LOAD_INPUT` errors on a missing key, a program must not
read a result it hasn't requested yet. The convention: on the first run a program
requests its effect, records a flag in `state` (e.g. `STATE_SET "requested"`), and
returns; the driver carries `state` forward, so on the next run the program takes
the "result is ready" branch and `LOAD_INPUT`s it. The driver's dedup-by-key makes
re-emitted intents harmless.

## 4. Concurrency
When a single run emits multiple intents (a batch), the driver performs them
**concurrently** (`Promise.all`) but writes the results back **in request order**,
and journals them in request order — so replay is deterministic regardless of which
effect's I/O finished first.

## 5. Journal (record / replay)
The journal is a serializable array, in request order:
```json
[ { "type_": "http.get",
    "key": "px",
    "payload": { "record": { "key": {"string":"px"}, "url": {"string":"https://…"} } },
    "result": { "string": "{\"symbol\":\"BTCUSDT\",\"price\":\"…\"}" } } ]
```
- **record (live):** `runLive` performs the real effect, appends `{type_,key,payload,result}`.
- **replay:** `runReplay` returns the next journaled result *without performing the
  effect* (synchronous, zero I/O); it never re-runs writes. A mismatch between the
  program's requested intents and the journal (wrong key/type or exhausted) is a
  hard error. Same journal ⇒ identical `value`, `events`, and `state`.

A crashed bot persists its journal, `runReplay`s it to restore state, then switches
to `runLive` to go live again. If you ever add time/randomness, journal it too
(never read the wall clock / `Math.random` during record).

## 6. Public JS API
```js
import { runLive, runReplay, createLiveHandlers, createMockHandlers,
         memoryStorage, createRegistry, valueToJs, jsToValue } from "./host/index.mjs";

// LIVE: perform effects, get a journal back
const { value, events, journal } = await runLive(programSource, {
  handlers: createLiveHandlers({ fetchImpl: fetch, storage: memoryStorage(), log: console.log }),
  input: {}, state: {},
});

// REPLAY: deterministic, synchronous, no I/O
const { value: v2 } = runReplay(programSource, journal);

// Custom handlers
const reg = createRegistry().register("http.get", async (p) => /* … */);
await runLive(programSource, { handlers: reg.handlers });
```
- `createLiveHandlers({ fetchImpl, storage, log })` — Node uses global `fetch` and
  `memoryStorage()` by default; a browser host passes `window.fetch` and an
  IndexedDB-backed storage with the same shape; a node deployment can pass a
  `node:sqlite`/`fs` storage. Storage is fully pluggable.
- `createMockHandlers({ "http.get": (p) => "…" })` — canned handlers for tests.
- `valueToJs`/`jsToValue` convert between the tagless Value JSON and plain JS.
  (Integers → number/BigInt; non-integer numbers map to strings — there is no
  float Value; build `VFixed`/`VRational` explicitly if you need them.)

## 7. Bundles
`npm run build` emits:
- `dist/finvm-core.js` — the CLI core (node).
- `dist/finvm-api.js` — the API the driver imports (`runEffectStep`,
  `runJsonProgramResult`), node, `big-integer` external.
- `dist/finvm-api.browser.js` — same API for the browser with **`big-integer`
  inlined**. **No `node:crypto`**: SHA-256 (`hash.sha256`, `db.hash`) is a pure-JS
  implementation and AES-GCM/PBKDF2 use `globalThis.crypto` (Web Crypto, present in
  browsers and Node ≥ 20), so hashing and encrypted DBs work identically on both
  ends — byte-for-byte the same digests. The only external is `node:fs/promises`,
  which the VM's DB persistence imports **dynamically and only on the Node path**;
  in the browser it is never reached (DB persistence uses `localStorage`).

## 8. Determinism guarantee
Per-instruction execution is the pure VM. The only effectful part is the driver,
and every effect result flows through the journal. **`runReplay` reproduces
`value` + `events` + `state` with zero I/O** — verified by `test/driver_test.js`
and, against a real endpoint, by `host/verify-binance.mjs` (live Binance fetch,
then replay with no network yields the identical body).
