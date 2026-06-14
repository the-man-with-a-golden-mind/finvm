# FinVM

A **universal deterministic virtual machine** implemented in PureScript. FinVM is a register-based bytecode VM designed as a substrate for auditable workflows, state machines, and distributed systems where the same `Program + Input + State` must always produce the exact same `Output + Trace`.

## Key properties

- **Deterministic** — no wall-clock, no RNG, no ordering nondeterminism. Logical ticks replace time; collections are canonically sorted.
- **Register-based** — O(1) register access; each function declares a fixed `registerCount`.
- **BigInt-native** — standard integers are arbitrary precision. Also supports fixed-point (`VFixed`) and rational (`VRational`) numerics.
- **Pure core** — the VM never touches the filesystem, network, or OS. Side effects are emitted as data ("Intents") or handled through explicit FFI builtins.
- **Concurrent** — Erlang-style lightweight processes with message passing and mailboxes.

## Install

```sh
npm install        # installs JS deps (esbuild, purescript, spago)
```

## Build

```sh
npm run build      # spago build + esbuild bundle -> dist/finvm-core.js
```

## Test

```sh
npm test           # PureScript spec suite (spago test) + JS DB tests
```

## Benchmark

```sh
npm run build      # required: the benchmark imports the compiled VM from output/
npm run bench      # FinVM vs native JS, and FinVM DB vs native JS data structures
# tune with env vars: VM_ITERS=20000 DB_SIZE=20000 REPS=5 npm run bench
```

The benchmark runs an arithmetic loop through the VM and compares it to the same
loop in native JS (with `big-integer` and with `Number`), and compares the
FinVM database (insert / indexed query / SHA-256 state hash) against an
equivalent native JS `Map`+index. FinVM is a safe, deterministic tree-walking
interpreter — it trades raw speed for determinism and auditability, so expect
the VM to be orders of magnitude slower than native code while the DB stays
within a small constant factor.

## CLI usage

After building (`dist/finvm-core.js` is the entry; `bin/finvm.js` is the executable):

```sh
finvm run <file.json>   # run a JSON bytecode program
finvm bench             # run the built-in statistics/graph benchmarks
```

### Performance mode

For throughput runs, add `"performanceMode": true` at the top level of the
program JSON. This disables per-step execution tracing and proof-trace
recording (the main per-instruction overhead) while producing **identical**
results — determinism is preserved; only the diagnostic trace is suppressed.
Leave it off (the default) when you need traces for debugging or replay. See
`npm run bench` for the measured speedup.

The runner prints a JSON result and exits non-zero if the program fails or the file cannot be read:

```sh
$ finvm run test/fixtures/cli-smoke.json
Loading program from: test/fixtures/cli-smoke.json
{"status":"completed","steps":5,"result":{"int":"42"},"state":{"answer":{"int":"42"}}}
```

## Minimal program

A program is JSON, using the tagless/positional form the runner accepts (see
[docs/LANGUAGE_SPEC.md](docs/LANGUAGE_SPEC.md)). The smallest meaningful one loads a
constant and halts:

```json
{
  "version": "1.0",
  "registerCount": 1,
  "constants": [ { "int": "42" } ],
  "instructions": [
    ["LOAD_CONST", 0, 0],
    ["HALT", 0]
  ]
}
```

## Documentation

- [docs/VM_SPEC.md](docs/VM_SPEC.md) — the VM contract: values, opcodes, ABI, limits, determinism
- [docs/LANGUAGE_SPEC.md](docs/LANGUAGE_SPEC.md) — compiler target: the exact JSON program/value format
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — code structure & execution pipeline
- [docs/TESTING.md](docs/TESTING.md) — spec / fuzz / stress / benchmark harnesses
- [docs/DECISIONS.md](docs/DECISIONS.md) — architecture decision records
- [docs/AGENTS.md](docs/AGENTS.md) — orientation for AI/automation working in the repo
- [docs/EFFECTS.md](docs/EFFECTS.md) — host effect driver (real I/O), intent contract, journal record/replay
- [docs/DATABASE.md](docs/DATABASE.md) — the encrypted/indexed/persistent DB and cache FFI
- [docs/IMPROVEMENT_PLAN.md](docs/IMPROVEMENT_PLAN.md) — known gaps and change history
- [LLM.txt](LLM.txt) — compact compiler-target reference for LLM/codegen consumers
- Also: [docs/SPEC.md](docs/SPEC.md), [docs/INSTRUCTION_SET.md](docs/INSTRUCTION_SET.md), [docs/COMPILER_TARGET.md](docs/COMPILER_TARGET.md), [docs/DEBUGGING.md](docs/DEBUGGING.md) (earlier notes)

## Project layout

```
src/FinVM/          VM core: Interpreter, Eval, Process, Numeric, Encoding, FFI
src/Main.purs       CLI entry point
test/               PureScript spec suite + JS DB tests
bench/              benchmarks
dist/               bundled output (built artifact)
```

## License

ISC.
