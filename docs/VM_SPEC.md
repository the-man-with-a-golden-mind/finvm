# FinVM — Virtual Machine Specification

The authoritative contract for the FinVM execution model. For the *JSON wire
format* a compiler emits, see [LANGUAGE_SPEC.md](LANGUAGE_SPEC.md); for internals,
see [ARCHITECTURE.md](ARCHITECTURE.md).

## 1. Design invariants
- **Deterministic.** `Program + Input + State` always yields the same
  `Output + State + Trace`. No wall-clock, no RNG, no ordering nondeterminism.
  Time is modeled as a logical tick; entropy must be passed in as input.
- **Register-based.** Each function declares a fixed `registerCount`; registers
  are O(1) `Value` slots, zero-indexed.
- **BigInt-native.** Integers are arbitrary precision. Exact fixed-point and
  rational numerics are first-class.
- **Pure core.** The VM never performs IO. Side effects are emitted as data —
  `Event`/`EffectIntent` values placed in the machine's `events`/`outbox` — or
  handled through explicit FFI builtins.
- **Concurrent.** Erlang-style lightweight processes with mailboxes and message
  passing, scheduled cooperatively and deterministically.

## 2. Values (the `Value` ADT)
`src/FinVM/Value.purs`. Wire encodings (tagless JSON) in
[LANGUAGE_SPEC.md](LANGUAGE_SPEC.md) §3.

| Value | Payload | Notes |
|---|---|---|
| `VUnit` | — | |
| `VBool` | Boolean | |
| `VInt` | BigInt | arbitrary precision |
| `VFixed` | `{ value: BigInt, scale: Int }` | decimal = `value × 10^-scale` |
| `VRational` | `{ numerator: BigInt, denominator: BigInt }` | not auto-normalized on decode |
| `VString` | String | |
| `VSymbol` | String | interned-style label |
| `VBytes` | Array Int | bytes 0..255 |
| `VList` | `Vec Value` | chunked vector: O(1) index/length, ~O(1) append |
| `VMap` | `Map Value Value` | ordered by `Value` Ord |
| `VRecord` | `Map String Value` | string-keyed |
| `VVariant` | `String × Value` | tagged union (tag + payload) |
| `VOption` | `Maybe Value` | |
| `VResult` | `Either Value Value` | err/ok |
| `VFunctionRef`, `VProcessRef`, `VRemoteProcessRef` | id/ref | |
| `VStateMachineInstance`, `VEvent`, `VEffectIntent`, `VProofValue` | — | runtime values |

`Value` has total `Eq`/`Ord`/`Show`. `Ord` is used for `VMap` keys and `LT/GT`
comparisons; canonical hashing uses a separate string encoding (`Canonical.purs`),
not `Ord`.

## 3. ABI (calling convention)
- A function's arguments are placed in registers `0 .. arity-1` at call time.
- Local/temporary values use registers `arity .. registerCount-1`.
- `registerCount` **must** be `>= arity` (else arguments would be dropped —
  enforced by `FinVM.Validate`).
- A function returns via `RETURN <reg>`; the value lands in the caller's
  destination register (the `dst` of the `CALL`).
- Constants are **program-global** (shared across all functions); `LOAD_CONST`
  indexes the top-level constant pool.

## 4. Instruction set
Each instruction is referenced here by opcode and argument order (see
[LANGUAGE_SPEC.md](LANGUAGE_SPEC.md) §5 for the exact JSON array form). `r`/`dst`
are register indices (Int); names/labels/keys are strings. Implemented in
`src/FinVM/Interpreter.purs`; the JSON decoder is `decodeInstruction`.

**Control flow:** `NOOP`, `HALT r`, `ABORT code`, `LABEL name`, `JUMP name`,
`JUMP_IF r name`, `JUMP_IF_FALSE r name`, `CALL dst funcId [args]`,
`TAIL_CALL funcId [args]`, `RETURN r`.

**Data movement:** `LOAD_CONST dst idx`, `LOAD_INPUT dst key`,
`LOAD_CONTEXT dst key`, `MOVE dst src`, `CLEAR dst`.

**Records:** `RECORD_NEW dst`, `RECORD_GET dst rec field`,
`RECORD_GET_OPT dst rec field`, `RECORD_SET dst rec field val`,
`RECORD_HAS dst rec field`, `RECORD_REMOVE dst rec field`, `RECORD_KEYS dst rec`.

**Lists:** `LIST_NEW dst`, `LIST_FROM dst [regs]`, `LIST_GET dst list idx`,
`LIST_SET dst list idx val`, `LIST_APPEND dst list val`, `LIST_LENGTH dst list`,
`LIST_SLICE dst list start end`.

**Maps:** `MAP_NEW dst`, `MAP_GET dst map key`, `MAP_GET_OPT dst map key`,
`MAP_SET dst map key val`, `MAP_HAS dst map key`, `MAP_REMOVE dst map key`,
`MAP_KEYS dst map`, `MAP_VALUES dst map`, `MAP_SIZE dst map`.

**Variants:** `VARIANT_NEW dst tag val`, `VARIANT_TAG dst v`,
`VARIANT_PAYLOAD dst v`.

**Arithmetic / compare:** `ADD/SUB/MUL/MOD dst a b`, `DIV dst rounding a b`
(rounding is a string — see §5), `NEG/ABS dst a`, `MIN/MAX dst a b`,
`CLAMP dst v lo hi`, `EQ/NEQ/LT/LTE/GT/GTE dst a b`, `COMPARE dst a b`.

**Builtins:** `CALL_BUILTIN dst "id@version" [args]`.

**Global state:** `STATE_GET dst key`, `STATE_GET_OPT dst key`,
`STATE_SET key src`, `STATE_DELETE key`, `STATE_EXISTS dst key`,
`STATE_KEYS dst prefix`, `STATE_SNAPSHOT dst`.

**Events / effect intents:** `EVENT_NEW dst type payload`, `EVENT_EMIT src`,
`EVENT_BATCH_NEW dst`, `EVENT_BATCH_APPEND dst batch event`, and the analogous
`EFFECT_*` opcodes. Emitting appends to the machine's `events`/`outbox` as data;
the host interprets them.

**Processes:** `PROC_SELF dst`, `PROC_STATUS dst pid`, `PROC_SPAWN dst funcId [args]`,
`PROC_YIELD`, `PROC_JOIN dst pid`, `PROC_JOIN_RESULT dst pid`, `PROC_CANCEL dst pid`,
`PROC_EXIT r`, `PROC_SEND pid msg`, `PROC_RECEIVE dst` (blocks),
`PROC_RECEIVE_OPT dst`, `PROC_LINK r`, `PROC_UNLINK r`, `PROC_MONITOR dst pid`,
`PROC_DEMONITOR ref`, `PROC_TRAP_EXIT bool`, `PROC_SLEEP_TICKS n`.

**Distribution (intents/metadata only — transport is a host concern):**
`NODE_SELF`, `NODE_STATUS`, `NODE_KNOWN`, `REMOTE_PID_*`, `NODE_SEND`,
`NODE_SPAWN`, `NODE_MONITOR`, `NODE_DEMONITOR`, `NODE_OBSERVE_STATE`,
`NODE_LAST_STATE_HASH`, `NODE_LAST_SEEN_TICK`, `NODE_QUERY_STATE`.

**State machines:** `MACHINE_NEW dst defId initReg`, `MACHINE_STATE dst inst`,
`MACHINE_TRANSITION dst inst event`.

**Proof / verification (recorded to `proofTrace`; suppressed in performanceMode):**
`ASSERT r code` (still checked — fails the process on false), `ASSUME r note`,
`INVARIANT_CHECK funcId`, `PROOF_MARK label r`, `PROOF_SCOPE_BEGIN/END label`.

## 5. Numerics
- **BigInt** (`Numeric/BigInt.purs`): `modAdd/Sub/Mul`, `modPow` (returns `Maybe`;
  `Nothing` when a negative exponent has no modular inverse), `extGcd`, `modInv`,
  `bitLength`.
- **Fixed** (`Numeric/Fixed.purs`): scaled integers. `add`/`sub` align to the max
  scale; `mul` adds scales; `div` returns the result at the **dividend's** scale
  using a supplied rounding mode (so `1/2` at scale 0 is `0`). Rounding modes:
  `RoundDown`, `RoundUp`, `RoundTowardZero`, `RoundAwayFromZero`, `RoundHalfEven`
  (correct for negative operands).
- **Rational** (`Numeric/Rational.purs`): normalized via gcd; `DivisionByZero` on a
  zero denominator.

## 6. Resource limits
`src/FinVM/Limits.purs`; defaults set in `decodeLimits` (`Encoding/Json.purs`).
Every limit below can be overridden via the top-level `limits` object in program
JSON (each field optional; absent fields use the default).

| Limit | Default | Enforced on |
|---|---|---|
| `maxSteps` | 10000 | total executed instructions |
| `maxCallDepth` / `maxFrames` | 256 / 1024 | call stack depth |
| `maxProcesses` | 1024 | live processes |
| `maxProcessStepsPerSlice` | 100 | fairness per scheduling slice |
| `maxRegistersPerFrame` | 1024 | a function's registerCount |
| `maxListLength` | 100000 | `LIST_FROM` |
| `maxMapSize` / `maxRecordFields` / `maxValueDepth` | 100000 / 10000 / 100 | structure size |
| `maxStateEntries` | 100000 | global state keys |
| `maxTraceEvents` / `maxProofEvents` | 100000 | trace growth |
| `maxMailboxSize` | 10000 | per-process mailbox |
| `maxEventsEmitted` / `maxEffectsRequested` | 10000 | emitted intents |

A program that exceeds `maxSteps` halts (the run returns; it does not loop
forever). Other overruns produce structured `VMError`s.

## 7. Concurrency & determinism
- The scheduler (`Process/Scheduler.purs`) picks the next ready process from a FIFO
  ready-queue — fully deterministic.
- `PROC_RECEIVE`/`PROC_JOIN` block by setting `ProcessWaiting` and re-execute the
  same instruction when woken. `PROC_SLEEP_TICKS` waits on a logical tick.
- On termination, monitoring processes receive a DOWN message
  (`VVariant "DOWN" { ref, pid, reason }`) and the monitor entry is cleared.
- Snapshots/replay (`Encoding/Snapshot.purs`) canonicalize state for stable
  hashing; the in-memory cache FFI is intentionally **excluded** from snapshots, so
  cache contents must never influence program output.

## 8. Errors
`src/FinVM/Error.purs` — `VMError ErrorCode String`. Notable codes:
`InvalidRegister`, `TypeMismatch`, `DivisionByZero`, `NoModularInverse`,
`ArithmeticError`, `UnknownFunction`, `UnknownBuiltin`, `ArityMismatch`,
`StepLimitExceeded`, `ProcessDeadlock`, `ProofAssertionFailed`.
</content>
