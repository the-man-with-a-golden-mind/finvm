# FinVM Debugging Guide

FinVM provides first-class tools for observing and verifying execution.

## 1. Execution Tracing
Every instruction executed is appended to the `trace` array in the `Machine` state when running in debug mode.

```purescript
import FinVM.Eval (debugRun)

-- Runs and prints all instructions to console
debugRun myMachine
```

## 2. Proof Traces
Use these instructions to build a verifiable audit log of your program's logic.

- `ASSUME`: Document preconditions (e.g., `ASSUME reg_x "x > 0"`).
- `ASSERT`: Enforce invariants. If it fails, execution halts immediately.
- `PROOF_MARK`: Capture intermediate variables for later verification.

## 3. Snapshots
The state of the entire machine (all processes, registers, mailboxes, and global state) can be captured at any point.

```purescript
import FinVM.Encoding.Snapshot (createSnapshot)

let s = createSnapshot machine
-- Produces a canonical string for replay comparison
```

## 4. Replay System
Because FinVM is 100% deterministic, any snapshot + input sequence will produce the exact same outcome.

- **Determinism**: No wall-clock, no randomness, no host IO.
- **Auditability**: Compare `expectedStateHash` against replayed `newStateHash`.
