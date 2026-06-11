# FinVM — Architecture

Internal structure and execution pipeline. Pairs with [VM_SPEC.md](VM_SPEC.md)
(the contract) and [AGENTS.md](AGENTS.md) (working conventions).

## Stack
PureScript (0.15) compiled by `spago` to ES modules under `output/`, bundled by
`esbuild` to `dist/finvm-core.js` (node platform), with `big-integer` as the one
runtime dependency. `bin/finvm.js` is the CLI shim.

## Execution pipeline
```
finvm run file.json
  └─ bin/finvm.js → dist/finvm-core.js (Main.main)
       └─ FinVM.Encoding.Json.runJsonProgram (String)
            ├─ decodeProgramFile      : String -> Either String JsonProgramFile
            │     (constants, functions/entrypoint, state, input, limits, perfMode)
            ├─ initialMachine         : seeds the entrypoint process + label cache
            └─ FinVM.Eval.runMachine  : Machine -> Either VMError Machine
                 └─ loop: Scheduler.nextProcess → runSliceForProcess
                      └─ FinVM.Interpreter.stepProcess (one instruction)
                           └─ evalInstruction (the ~100-case dispatch)
       └─ encode result → { status, steps, result, state } JSON
```
Note: `runJsonProgram` does **not** call `FinVM.Validate.validateProgram`; the CLI
trusts the program and surfaces problems as runtime `VMError`s.

## Core types
- **`Machine`** (`Machine.purs`): `program`, `scheduler`, `state` (global K/V),
  `input`, `config` (`limits`, `externalBuiltins`, `performanceMode`), `trace`,
  `proofTrace`, `outbox` (effect intents), `events`, `counters` (steps), and
  `labelCache` (per-function `label → pc`).
- **`Process`** (`Process.purs`): `pid`, `status`, current `frame`, `callStack`,
  `mailbox`, `links`/`monitors`, `parent`/`children`, `trapExit`, `result`/`error`,
  step counters. `ProcessStatus` = Ready / Running / Waiting(cond) / Completed /
  Failed / Cancelled / Exited.
- **`Frame`** (`Frame.purs`): `function`, `pc`, `registers :: Array Value`,
  `returnRegister`, `caller`.
- **`Program`** (`Program.purs`): version, constants, `functions` map,
  stateMachines, entrypoint, exports, metadata, typeTable, capabilities,
  verification.
- **`Value`** (`Value.purs`): see [VM_SPEC.md](VM_SPEC.md) §2.

## The interpreter (`Interpreter.purs`)
- `stepProcess m p`: fetch the instruction at the frame's `pc`, increment step
  counters, optionally append a trace event (skipped in `performanceMode`), then
  `evalInstruction`.
- `evalInstruction m p func inst`: a single big `case inst of` returning
  `Either VMError (Tuple Machine Process)`. Each branch reads registers
  (`readReg`), computes, and writes via `writeReg`/`pNextPc` (advance PC).
- Jump targets resolve through `findLabel`, which uses `Machine.labelCache`
  (built once per run by `Eval.runMachine`) for O(1) lookup, falling back to a
  linear scan for direct callers that didn't populate the cache.

## The scheduler & slice loop (`Eval.purs`, `Process/Scheduler.purs`)
- `Scheduler` holds the `processes` map, a FIFO `readyQueue`, the current pid, the
  pid sequence, and the `logicalTick`. `nextProcess` pops the ready queue
  deterministically.
- `runMachine` runs slices until all processes finish, a limit trips, or deadlock.
  Each slice runs up to `maxProcessStepsPerSlice` instructions for one process,
  then re-queues it by status.
- `wakeProcessWaiters` wakes processes blocked on a now-completed process;
  `wakeNextTick` advances the logical tick to the minimum waiting tick;
  `notifyMonitorsOfDeath` delivers DOWN messages and clears monitor entries on
  terminal status.

## Lists: `FinVM.Vec`
`VList` is backed by a **persistent chunked vector** (`Vec.purs`): fixed-size
blocks (`blockSize = 256`) plus a partial tail. Index/length are O(1); append is
amortized ~O(1); `Eq`/`Ord`/`Show` are defined over the logical sequence so list
semantics (comparison, canonical hashing, display) match a plain array. This
replaced an `Array` backing whose `snoc` made list-building O(n²). See
[DECISIONS.md](DECISIONS.md) ADR-0007.

## Encoding & hashing (`Encoding/`)
- `Json.purs` — the program/value codec and the `runJsonProgram*` entry points.
- `Canonical.purs` — deterministic `Value → String` + SHA-256 (`Canonical.js`),
  with records/maps sorted by key so hashing is order-independent.
- `Snapshot.purs` — canonical machine snapshot (program version, sorted state,
  per-process registers/mailbox, tick, steps). The cache FFI is excluded.
- `Replay.purs` — snapshot/replay state & output hash verification.

## FFI boundary (`FFI/`)
- `Database.js` (`FinVMDatabase`, `nativeDb`): in-memory tables + indices, MongoDB-
  style query, AES-256-GCM persistence with PBKDF2 key derivation + per-DB salt,
  SHA-256 table hash. PureScript-side signatures/registry in
  `Builtin/Database.purs`.
- `Cache.js` (`FinVMCache`, `nativeCache`): namespaced in-memory K/V; non-
  persisted; intentionally excluded from determinism (must not affect output).
- **Wiring gap:** these registries are *not* injected by `Main.purs`, so they're
  unavailable via the CLI today (`externalBuiltins: Map.empty`).

## Numerics (`Numeric/`)
`BigInt` (re-exports `Data.BigInt` + modular arithmetic), `Fixed` (scaled ints +
rounding), `Rational` (gcd-normalized), `Rounding` (the five modes). See
[VM_SPEC.md](VM_SPEC.md) §5.

## Module index
```
src/Main.purs                     CLI (run / bench)
src/Benchmark/{Graph,Statistics}  PureScript-side benchmark workloads
src/FinVM/
  Interpreter.purs                per-instruction execution
  Eval.purs                       scheduler slice loop + wake/monitor logic
  Machine.purs                    Machine / EvalConfig / counters
  Process.purs                    Process / ProcessStatus / WaitCondition
  Process/Scheduler.purs          deterministic scheduler
  Validate.purs                   static program validation (NOT on CLI path)
  Limits.purs                     EvalLimits
  Builtin.purs                    built-in registry + dispatch
  Builtin/{Database,Cache}.purs   host-injected builtin signatures/registries
  Encoding/{Json,Canonical,Snapshot,Replay}.purs
  Numeric/{BigInt,Fixed,Rational,Rounding}.purs
  StateMachine/{Instance,Transition}.purs
  Proof/ProofTrace.purs           proof event types
  Debug/Trace.purs                trace event types
  FFI/{Database,Cache}.js + Canonical.js
  Value.purs Vec.purs Frame.purs Function.purs Instruction.purs Program.purs
  Registers.purs State.purs Type.purs Error.purs
```
</content>
