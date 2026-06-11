# FinVM — Compiler Target / Language Spec

How a high-level language compiles to FinVM. This is the **exact JSON wire format**
accepted by `finvm run <file.json>` / `runJsonProgram` (decoder:
`src/FinVM/Encoding/Json.purs`). It complements [VM_SPEC.md](VM_SPEC.md) (the
execution model) and mirrors the compact `../LLM.txt`.

> Format note: constants and instructions are **TAGLESS / POSITIONAL**. There is
> **no** `{ "tag", "contents" }` decoder — that form decodes as a `VRecord`.

## 1. Program JSON

### Single-function (simplified) form
```json
{
  "version": "1.0",
  "registerCount": 10,                 // registers for the implicit `main` (>= arity)
  "performanceMode": false,            // optional: disables tracing/proofs for speed
  "limits": { "maxSteps": 100000 },    // optional: only maxSteps is read (default 10000)
  "constants": [ { "int": "42" }, { "string": "hi" } ],
  "state": {},                         // optional: { "key": <Value> }
  "input": {},                         // optional: { "key": <Value> }
  "instructions": [ ["LOAD_CONST", 0, 0], ["HALT", 0] ]
}
```

### Multi-function form (for CALL / TAIL_CALL / PROC_SPAWN)
Provide a top-level `functions` map (key = function id) and an `entrypoint`.
Constants stay program-global.
```json
{
  "version": "1.0",
  "constants": [ { "int": "40" }, { "int": "2" } ],
  "entrypoint": "main",
  "functions": {
    "main":   { "arity": 0, "registerCount": 4, "instructions": [
                  ["LOAD_CONST",0,0], ["LOAD_CONST",1,1], ["CALL",2,"addTwo",[0,1]], ["RETURN",2] ] },
    "addTwo": { "arity": 2, "registerCount": 4, "instructions": [ ["ADD",2,0,1], ["RETURN",2] ] }
  }
}
```
Per-function fields: `arity` (default 0), `registerCount` (default `max(16, arity)`;
must be `>= arity`), `instructions` (required), optional `proof: {isInvariant}`.
Recursion and `PROC_SPAWN` of any defined function work. The simplified form still
works (it builds a single implicit `main`).

### Run output
```json
{ "status": "completed" | "failed" | "error",
  "steps": 5, "result": <Value>, "state": { "<key>": <Value> } }
```
The CLI exits non-zero on `failed`/`error`.

## 2. Instructions: wire form
Every instruction is a JSON array `["OPCODE", ...args]` (object form
`{"op":"OPCODE","args":[...]}` also accepted). Argument order matches
[VM_SPEC.md](VM_SPEC.md) §4. Registers are integers; labels/fields/keys are strings.
Examples:
```
["LOAD_CONST", dst, constIndex]
["ADD", dst, a, b]
["DIV", dst, "RoundDown", a, b]      // rounding mode is a STRING at position 2
["JUMP_IF_FALSE", condReg, "label"]
["STATE_SET", "key", srcReg]         // key first, then register
["CALL", dst, "funcId", [argReg, ...]]
["CALL_BUILTIN", dst, "id@version", [argReg, ...]]
```

## 3. Value JSON encodings
Used for `constants`, `state`, `input`, and round-tripped in the output:
```
VUnit     -> null
VBool     -> { "bool": true }
VInt      -> { "int": "42" }          // decimal string (bare safe ints also OK)
VFixed    -> { "fixed": { "value": "12345", "scale": 2 } }     // 123.45
VRational -> { "rational": { "numerator": "22", "denominator": "7" } }
VString   -> { "string": "hello" }
VSymbol   -> { "symbol": "name" }
VBytes    -> { "bytes": [1,0,2] }
VList     -> { "list": [ <Value>, ... ] }
VMap      -> { "map": [ { "key": <Value>, "value": <Value> }, ... ] }
VRecord   -> { "record": { "field": <Value>, ... } }
VVariant  -> { "variant": { "tag": "Name", "payload": <Value> } }
```
An object with none of these keys decodes as a `VRecord` of its fields.

## 4. Compilation guidelines
1. **Registers.** Map locals to registers; reuse registers as variables go out of
   scope to keep `registerCount` small. Arguments occupy `0..arity-1`.
2. **Control flow.** Compile loops to `LABEL`/`JUMP`/`JUMP_IF*`. Compile recursive
   tail calls to `TAIL_CALL` (the VM is tail-call optimized). Use `CALL` for
   non-tail calls; the callee must be in the `functions` map.
3. **Numbers.** Default integers are `VInt` (exact, unbounded). For decimals use
   `VFixed` (pick a scale; `DIV` rounds to the dividend's scale — widen the
   dividend's scale first if you need more fractional digits). For exact ratios use
   `VRational`.
4. **Collections.** `VList` append is amortized ~O(1) (building an N-list is ~O(N));
   `VRecord`/`VMap` for keyed data. Prefer fewer, larger constructs over deeply
   nested per-element ops where possible.
5. **Guard types.** A type mismatch at runtime raises `TypeMismatch` and fails the
   process — emit code that produces the expected `Value` shapes.
6. **Performance mode.** Emit `"performanceMode": true` for production/throughput
   runs (identical results; only diagnostic trace/proof recording is suppressed).
   The proof opcodes (`ASSERT`/`INVARIANT_CHECK`/`PROOF_*`) are effectively free in
   this mode, so you needn't avoid them for speed.

## 5. Behavior to encode in your codegen
- `bigint.modPow@1` **fails** (`NoModularInverse`) on a non-invertible negative
  exponent — handle the error, don't expect `0`.
- `Fixed` division rounds correctly for negative operands.
- `db.hash@1` returns a SHA-256 hex digest (64 chars).
- `VFixed`/`VRational`/`VMap` are valid constants and round-trip correctly.
- A process monitoring another receives `VVariant "DOWN" {ref,pid,reason}` on its
  death.

## 6. Current limitations to plan around
- **`finvm run` validates up front** — `validateProgram` runs after decode, so
  unknown function/label, arity mismatch, out-of-bounds register, and
  `registerCount < arity` are reported as a `failed` status before execution.
  (Builtin availability is still only checked when a `CALL_BUILTIN` executes.)
- **`db.*` / `cache.*` builtins are not available via `finvm run`** — the CLI runs
  with no external builtins. `CALL_BUILTIN "db.insert@1"` will fail with
  `UnknownBuiltin` unless a host wires the registries (see
  [DECISIONS.md](DECISIONS.md) / [DATABASE.md](DATABASE.md)).
- **Only `maxSteps` is configurable from JSON**; other limits use defaults.
- **Distribution opcodes** (`NODE_*`/remote) produce intents/metadata only; there is
  no built-in transport.
</content>
