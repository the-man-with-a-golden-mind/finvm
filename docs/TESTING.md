# FinVM — Testing

Four layers: unit/spec tests, a JS DB test, a random-program fuzzer, and
scale/throughput benchmarks. Determinism is the central property and is checked
explicitly.

## Commands
```sh
npm test            # spago test (PureScript specs) + node test/db_test.js
npm run test:purs   # PureScript spec suite only (Test.Main)
npm run test:js     # JS DB security/feature tests only
npm run fuzz        # random-program no-crash + determinism (test/fuzz.js)
npm run stress      # scale/perf harness (bench/stress.js)
npm run bench       # FinVM vs native JS, VM-DB vs native data structures
```
Current status: **spago build clean, 89/89 specs + JS DB tests pass; 10k-program
fuzz is crash-free and fully deterministic.**

## 1. PureScript spec suite (`test/`, runner `test/Main.purs`)
`spago`-built specs using `spec` + `spec-quickcheck`. Modules:

| Area | Module |
|---|---|
| Interpreter / opcodes | `Test/Interpreter.purs`, `Test/InstructionSet.purs` |
| Validation | `Test/Validate.purs` (incl. registerCount ≥ arity) |
| Numerics | `Test/Numeric/{BigInt,Fixed,Rational}.purs` |
| JSON codec | `Test/Encoding/Json.purs` (round-trip + QuickCheck fuzz) |
| Canonical hashing | `Test/Encoding/Canonical.purs` |
| Concurrency | `Test/Process.purs`, `Test/Monitor.purs` (DOWN cleanup) |
| State machines | `Test/StateMachine.purs` |
| Proof / remote | `Test/Proof.purs`, `Test/Remote.purs` |
| DB / cache builtins | `Test/Database.purs`, `Test/Cache.purs` |
| End-to-end / conformance | `Test/E2E.purs`, `Test/Conformance.purs` |
| Replay / snapshots | `Test/Replay.purs` |
| Performance mode | `Test/PerformanceMode.purs` (trace suppression) |
| Property tests | `Test/Properties.purs` (QuickCheck) |

To add a spec: create `test/Test/<Area>.purs` exporting `spec :: Spec Unit`, then
import and call it in `test/Main.purs`. Conformance tests drive whole programs
through `runJsonProgram` (JSON in, JSON out) — prefer these for behavior that a
compiler relies on.

## 2. JS DB tests (`test/db_test.js`)
Exercises `FinVMDatabase` directly (not through the VM): CRUD, indices,
deterministic SHA-256 table hashing (incl. key-order independence), AES-GCM
encryption + persistence round-trip, wrong-key failure, no-key-no-persist, and a
prototype-pollution regression for query keys. Run with `node test/db_test.js`.

## 3. Fuzzer (`test/fuzz.js`)
Generates random *valid-by-construction* programs (registers in range, jumps to
declared labels, step-capped) and runs each through `runJsonProgram` twice,
asserting two invariants:
1. **No host crash** — every input yields parseable JSON with a `status` field
   (an uncaught exception or unparseable output is a failure).
2. **Determinism** — the two runs produce byte-identical output.

Deterministic seed → reproducible. Tune via env:
```sh
FUZZ_ITERS=50000 FUZZ_SEED=123 node test/fuzz.js
```
This is the primary safety net for changes to the interpreter, the `Value`
representation, or any ordering-sensitive path. Note: it catches crashes and
*non*determinism, not all correctness regressions — pair it with the spec suite.
To probe new opcodes, extend the instruction generator in `test/fuzz.js`.

## 4. Stress / scale (`bench/stress.js`)
Pushes the VM and DB at size and checks correctness + determinism + peak heap:
a long arithmetic loop, a large list build (verifies ~O(N), not O(N²)), and a
large indexed/hashed DB. Tune via `LOOP_N`, `LIST_N`, `DB_N`.

## 5. Benchmarks (`bench/vm_vs_js_benchmark.js`)
Compares FinVM (tracing vs performanceMode) against native JS (`big-integer` and
`Number`), the O(1) label-cache behavior, and the VM-DB against a native `Map`+
index. Use it to track regressions and the effect of perf changes. Expect FinVM
~100–200× slower than native bigint — that is the inherent cost of a pure,
deterministic tree-walking interpreter (see [DECISIONS.md](DECISIONS.md) ADR-0008).

## Determinism: the rule for changes
Any change that could affect output ordering (Map iteration, list ops, hashing,
scheduling) must keep two runs byte-identical. Validate with `npm test` **and**
`npm run fuzz` before considering a change safe. When changing `VList`/codec/
canonical paths, also re-run `npm run stress` for scale behavior.
</content>
