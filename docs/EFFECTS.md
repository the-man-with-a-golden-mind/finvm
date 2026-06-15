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
The host now uses the snapshot/resume API, not whole-program re-run:

1. `runEffectStart(program, overrides)` runs the VM to quiescence and returns:
   - `status`: `suspended` | `completed` | `deadlock`
   - `snapshot`: resumable execution state
   - `pending`: ordered items with explicit kind:
     - await-reply: `{ kind: "await_reply", pid, key, type_, payload }`
     - transport: `{ kind: "transport", pid, type_, payload }`
   - plus `events`, `result`, `state`
2. If `status == "suspended"`, the driver performs `pending` effects.
3. Build `deliveries` in request order using explicit envelopes:
   - effect reply: `{ pid, key, result }`
   - mailbox message: `{ pid, message }`
   - disconnect signal: `{ disconnect: { node, reason? } }`
   - node lifecycle update:
     `{ nodeStatus: { node, status, reason?, lastSeenTick?, lastStateHash? } }`
4. `runEffectResume(program, snapshot, deliveries)` continues from the exact
   machine state and runs again to quiescence.
5. Repeat until `status == "completed"` (or classify deadlock/error).

This model suspends only the waiting process (`EFFECT_AWAIT`) while other actors
can continue running and mutating state before quiescence.

### Selective receive for async replies
- Effect replies are delivered as mailbox variants:
  `VVariant "EffectReply" { key, value }`.
- `PROC_RECEIVE` stays FIFO and may consume unrelated earlier messages first.
- For Erlang-style selective receive, use:
  - `PROC_RECEIVE_MATCH dst tagReg` (blocking)
  - `PROC_RECEIVE_MATCH_OPT dst tagReg` (non-blocking)
- These opcodes scan mailbox order for the first matching variant tag, remove only
  that element, and keep all other messages in place.
- A process waiting on `WaitingOnMatch tag` is woken only when a delivery/send
  leaves a matching `VVariant tag _` in its mailbox (no wake on arbitrary messages).

### Remote monitor intents and disconnect delivery
- `NODE_MONITOR` emits `RemoteMonitorIntent` and stores a monitor ref in-process.
- `NODE_DEMONITOR` removes that ref and emits `RemoteDemonitorIntent`.
- `NODE_LINK` emits `RemoteLinkIntent`; `NODE_UNLINK` emits `RemoteUnlinkIntent`.
- The host can notify a transport/node break with a resume delivery:
  `{ "disconnect": { "node": "<nodeName>", "reason": "<optional>" } }`.
- On resume, every process monitoring remote refs on that node receives a mailbox
  `DOWN` message (`{ tag: "DOWN", payload: { ref, pid, reason } }` in VM Value
  form), those monitor refs are removed, and waiters blocked on mailbox/monitor are
  woken deterministically.
- For remote links on that node: trap-exit processes receive mailbox
  `EXIT` messages; non-trapping processes exit with the disconnect reason.
- If `reason` is omitted, VM defaults to `"noconnection"`.

## 4. Concurrency + determinism
When a single quiescent step exposes multiple `pending` effects, the driver may
perform them **concurrently** (`Promise.all`), but it must:

- preserve **request-order deliveries** when calling `runEffectResume`
- preserve **request-order journal entries**

Handlers may finish out-of-order; replay remains deterministic because resume and
journal ordering are stable.

For transport intents (`kind: "transport"`), handlers can return delivery hints:
- `{ delivery: <envelope> }` or `{ deliveries: [<envelope>, ...] }`
- envelopes use the same resume-delivery shapes above (`message`, `disconnect`,
  `nodeStatus`, and effect replies when needed).
- live mode converts these hints into resume deliveries; replay reconstructs the
  same deliveries from journaled transport results.

## 5. Journal (record / replay)
The journal is a serializable array, in request order:
```json
[ { "pid": "p0",
    "type_": "http.get",
    "key": "px",
    "payload": { "record": { "key": {"string":"px"}, "url": {"string":"https://…"} } },
    "result": { "string": "{\"symbol\":\"BTCUSDT\",\"price\":\"…\"}" } } ]
```
- **record (live):** `runLive` appends `{pid,key,type_,payload,result}`.
- **replay:** `runReplay` consumes the next journal entry *without performing I/O*.
  Mismatch on `pid`/`key`/`type_` (or exhausted journal) is a hard error.
  Same program + same journal => identical `value`, `events`, and `state`.

For node disconnects, the host injects a `disconnect` delivery when resuming. That
signal is external transport state, so it is replay-safe as long as it is provided
explicitly in the same resume input.

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
- `dist/finvm-api.js` — the API the driver imports (`runEffectStart`,
  `runEffectResume`, `runEffectStep`, `runJsonProgramResult`), node,
  `big-integer` external.
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
`value` + `events` + `state` with zero I/O** — including multi-actor await
scenarios where handlers complete out-of-order.
