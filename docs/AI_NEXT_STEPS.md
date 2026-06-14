# FinVM Distributed VM — AI Next Steps

Execution plan for AI agents continuing the distributed Erlang-style actor work.
This document is intentionally operational: what to change, in what order, and
what tests must pass before shipping each step.

## Current status (what is already done)

- Async effect suspend/resume exists (`runEffectStart` / `runEffectResume`).
- `EFFECT_AWAIT` semantics are implemented and tested.
- Cross-VM message delivery baseline exists via `NODE_SEND` -> host transport ->
  mailbox delivery on resume.
- Remote monitor baseline exists:
  - `NODE_MONITOR` / `NODE_DEMONITOR` emit intents.
  - Disconnect delivery injects deterministic `DOWN` messages.
- Monitor bookkeeping now uses typed monitor targets internally
  (`MonitorLocal` / `MonitorRemote`) instead of string markers.
- Replay determinism and mailbox/snapshot behavior have dedicated tests.

Do **not** redesign from scratch. Extend incrementally from this baseline.

## Core constraints (non-negotiable)

1. Determinism first:
   - identical program + identical resume inputs/journal => identical output.
2. VM core stays pure:
   - all network/transport behavior is modeled as intents + resume deliveries.
3. Backward compatibility:
   - avoid breaking existing JSON program format and existing tests unless a
     deliberate spec change is documented.
4. Keep changes reviewable:
   - one feature slice per commit/PR.

## Priority roadmap

### Step 1 — Unify pending intent and delivery envelope

Goal: remove ad-hoc optional field logic and make intent/delivery handling
explicit and safer for future features.

#### Changes
- Introduce a normalized internal "pending item kind" concept:
  - `AwaitReplyPending` (requires `{ pid, key, type_, payload }`)
  - `TransportPending` (requires `{ type_, payload }`, optional pid)
- Introduce explicit delivery variants in JSON decode path:
  - effect reply: `{ "pid": "...", "key": "...", "result": <Value> }`
  - mailbox message: `{ "pid": "...", "message": <Value> }`
  - disconnect event: `{ "disconnect": { "node": "...", "reason": "..." } }`
- Centralize validation and normalization in one place in
  `src/FinVM/Encoding/Json.purs`.

#### Why
- Prevents subtle bugs from ambiguous optional fields.
- Makes host driver simpler and less branchy.

#### Required tests
- Extend `test/Test/Effects.purs` for each delivery variant.
- Extend `test/driver_test.js` to assert invalid envelopes fail clearly.

---

### Step 2 — Typed monitor targets (remove stringly-typed remote markers)

Goal: avoid brittle monitor bookkeeping.

#### Changes
- Replace string marker conventions in monitors with typed representation:
  - local target pid
  - remote target `{ node, pid }`
- Keep public VM behavior unchanged.
- Update monitor cleanup and disconnect traversal to use typed structure.

#### Why
- Reduces parsing errors and accidental key collisions.
- Necessary before adding richer monitor/link semantics.

#### Required tests
- `test/Test/Remote.purs`: monitor register/deregister invariants.
- `test/Test/Snapshot.purs`: typed monitor refs round-trip stable.
- `test/Test/Effects.purs`: disconnect still produces deterministic `DOWN`.

---

### Step 3 — Node status lifecycle and failure reasons

Goal: define and enforce node connectivity semantics.

#### Changes
- Implement explicit node status transitions (e.g. `online`, `suspect`,
  `offline`) as host-supplied deterministic events.
- Standardize disconnect reasons:
  - `noconnection`, `timeout`, `unreachable`, `shutdown`, `killed`.
- Ensure `NODE_STATUS` reflects modeled state, not implicit assumptions.

#### Why
- Needed for predictable distributed supervision behavior.

#### Required tests
- Add failure-path tests in `test/Test/Remote.purs` and driver integration:
  - monitor receives expected reason.
  - reason stays replay-stable.

---

### Step 4 — NODE_SPAWN completion semantics

Goal: make remote spawn usable by real actor workflows.

#### Changes
- Define spawn handshake:
  - success => stable remote pid ref.
  - failure => deterministic error/delivery path.
- Add transport intent contract for spawn ack/fail.

#### Why
- Remote send without robust remote spawn is only half a distributed actor model.

#### Required tests
- Happy-path spawn and first message exchange.
- Spawn failure reason propagation.
- Replay determinism for both success and failure.

---

### Step 5 — Remote links parity (after monitors are stable)

Goal: approach Erlang-like behavior for linked distributed actors.

#### Changes
- Implement `NODE_LINK` / `NODE_UNLINK` equivalent semantics (or extend
  existing ops if already encoded by instruction set decisions).
- Propagate exit/disconnect according to trap-exit semantics.

#### Why
- Supervisory trees across nodes require links + monitor interplay.

#### Required tests
- Link propagation on remote death/disconnect.
- Trap-exit true/false behavior parity.
- Replay determinism for exit storms.

## Testing policy for every distributed change

Before merging any step above, run all:

```sh
XDG_CACHE_HOME="$PWD/.cache" npm run test:purs
XDG_CACHE_HOME="$PWD/.cache" npm run bundle:api && npm run test:driver
XDG_CACHE_HOME="$PWD/.cache" npm test
npm run fuzz
```

Notes:
- `npm run fuzz` is required when changing execution semantics, snapshot/replay,
  or value encoding paths.
- If any test is flaky, fix determinism or ordering assumptions before merge.

## Suggested file ownership map

- VM semantics:
  - `src/FinVM/Interpreter.purs`
  - `src/FinVM/Process.purs`
  - `src/FinVM/Eval.purs`
- JSON/codec + resume delivery:
  - `src/FinVM/Encoding/Json.purs`
  - `src/FinVM/Encoding/Resume.purs`
- Host adapter:
  - `host/driver.mjs`
  - `host/handlers.mjs`
- Tests:
  - `test/Test/Effects.purs`
  - `test/Test/Remote.purs`
  - `test/Test/Snapshot.purs`
  - `test/driver_test.js`
- Docs:
  - `docs/EFFECTS.md`
  - `docs/VM_SPEC.md`
  - `docs/ARCHITECTURE.md`

## Definition of done (for each step)

1. Behavior documented in `docs/` (not just code comments).
2. PureScript + driver tests added/updated for happy/failure/determinism.
3. Full required test matrix green.
4. No unrelated file changes in commit.
5. Commit message explains intent (why), not just file names.

## Anti-patterns to avoid

- Encoding transport policy directly into VM core.
- Mixing envelope schemas ad hoc in multiple places.
- Hardcoding process IDs in tests when runtime-assigned IDs are available.
- Adding broad features without first pinning determinism/replay tests.

