# AGENTS.md — guide for AI / automation working in this repo

Orientation for coding agents. Read this first; it captures the non-obvious facts
that the source doesn't make visible.

## What this is
FinVM — a deterministic, register-based bytecode VM written in PureScript
(compiled to JS via `spago` + bundled with `esbuild`). See
[ARCHITECTURE.md](ARCHITECTURE.md) and [VM_SPEC.md](VM_SPEC.md).

## Commands
```sh
npm install         # JS deps (purescript, spago, esbuild, big-integer)
npx spago build     # compile PureScript -> output/ (fast; use during dev)
npm run build       # spago build + esbuild bundle -> dist/finvm-core.js
npm test            # spago test (PureScript specs) + node test/db_test.js
npm run fuzz        # random-program no-crash + determinism check (test/fuzz.js)
npm run stress      # scale/perf harness (bench/stress.js)
npm run bench       # FinVM vs native JS, and VM-DB vs native data structures
```

## Critical gotchas (these will bite you)
1. **The CLI runs the bundle, not `output/`.** `bin/finvm.js` imports
   `dist/finvm-core.js`. After any source change, `npx spago build` updates
   `output/` (used by tests/fuzz/bench, which import from `output/` directly) but
   **NOT** `dist/`. Run `npm run build` before testing the `finvm run` CLI.
2. **Program JSON is TAGLESS / POSITIONAL**, not `{tag,contents}`. Constants are
   `{"int":"42"}`; instructions are `["ADD",dst,a,b]`. The only decoder is
   `decodeProgramFile` in `src/FinVM/Encoding/Json.purs`. See
   [LANGUAGE_SPEC.md](LANGUAGE_SPEC.md).
3. **The CLI validates before running.** `runJsonProgram` runs
   `FinVM.Validate.validateProgram` after decode, so structural problems (unknown
   function/label, arity mismatch, out-of-bounds register, `registerCount < arity`)
   surface as a `failed` status *before* execution rather than as opaque runtime
   errors. (Builtin availability is still checked at call time, not validation.)
4. **`db.*` and `cache.*` builtins are NOT wired into the CLI.** `initialMachine`
   sets `externalBuiltins: Map.empty`, so `CALL_BUILTIN "db.insert@1"` fails with
   UnknownBuiltin via `finvm run`. The registries exist
   (`FinVM.Builtin.Database.createDbRegistry`, `…Cache.createCacheRegistry`) but
   are only used in unit tests. (Known gap — see [DECISIONS.md](DECISIONS.md).)
5. **All `EvalLimits` are configurable** via the top-level `limits` object — each
   field is optional and falls back to its default (`decodeLimits`). E.g.
   `"limits": { "maxSteps": N, "maxListLength": M, "maxProcesses": P }`.
6. **Lists are `FinVM.Vec`, not `Array`.** `VList` wraps a chunked vector. Use
   `Vec.fromArray`/`Vec.toArray`/`Vec.snoc`/`Vec.index`/`Vec.length`, never
   `Array.*`, when constructing/inspecting `VList`.

## Conventions
- Match the surrounding style; PureScript is layout-sensitive — prefer rewriting a
  whole `let`/`case` block over fragile partial edits.
- Determinism is the core invariant: no wall-clock, no RNG, no ordering
  nondeterminism (Maps are canonically sorted for hashing). Any change that could
  affect output ordering must keep two runs byte-identical — `npm run fuzz` checks
  this over thousands of random programs.
- After changing the `Value` type or any list/codec path, run `npm test` **and**
  `npm run fuzz` (the fuzzer's determinism check is the safety net).

## Where things live
- Execution: `src/FinVM/Interpreter.purs` (per-instruction), `Eval.purs` (scheduler
  loop), `Process/Scheduler.purs`.
- JSON in/out: `src/FinVM/Encoding/Json.purs` (the program/value codec + CLI entry
  glue), `Canonical.purs` (hashing), `Snapshot.purs`/`Replay.purs`.
- Numerics: `src/FinVM/Numeric/{BigInt,Fixed,Rational,Rounding}.purs`.
- FFI: `src/FinVM/FFI/{Database,Cache}.js`.
- CLI: `src/Main.purs`.

## Docs map
- [VM_SPEC.md](VM_SPEC.md) — the VM contract (types, opcodes, limits, determinism)
- [LANGUAGE_SPEC.md](LANGUAGE_SPEC.md) — how to compile a language to FinVM JSON
- [ARCHITECTURE.md](ARCHITECTURE.md) — code structure & execution pipeline
- [TESTING.md](TESTING.md) — test/fuzz/stress/bench harnesses
- [DECISIONS.md](DECISIONS.md) — architecture decision records
- [EFFECTS.md](EFFECTS.md) — host effect driver, intent contract, journal (record/replay)
- [DATABASE.md](DATABASE.md) — DB/cache FFI
- [IMPROVEMENT_PLAN.md](IMPROVEMENT_PLAN.md) — known gaps & history
- `../LLM.txt` — compact compiler-target reference
</content>
