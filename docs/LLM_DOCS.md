# LLM Guide to FinVM

This document helps Large Language Models (LLMs) understand how to generate code for and reason about the FinVM virtual machine.

## VM Model
- **Type**: Register-based.
- **State**: Pure functional transitions.
- **Language**: PureScript (Implementation), Bytecode (Target).
- **BigInt**: Arbitrary precision is the default for all integer math.
- **Processes**: Lightweight, Erlang-inspired. No OS threads.

## Bytecode Structure
A program is a collection of functions. Each function has a `registerCount`. Registers are accessed by 0-based integer indexes.

For CLI execution, emit JSON with `constants`, `registerCount`, and array-form `instructions`:

```json
{
  "constants": [{ "int": "40" }, { "int": "2" }],
  "registerCount": 4,
  "instructions": [
    ["LOAD_CONST", 0, 0],
    ["LOAD_CONST", 1, 1],
    ["ADD", 2, 0, 1],
    ["RETURN", 2]
  ]
}
```

### Function Signature
```purescript
{ id: "my_func"
, arity: 2
, registerCount: 5
, instructions: [...]
}
```

## Key Instruction Patterns

### 1. Simple Arithmetic
```text
LOAD_CONST 0 0 -- Load first constant into r0
ADD 1 0 1      -- r1 = r0 + r1
```

### 2. Loops (Using Labels)
```text
LABEL "loop"
EQ 2 0 1      -- r2 = (r0 == r1)
JUMP_IF 2 "end"
-- body --
JUMP "loop"
LABEL "end"
```

### 3. Process Communication
```text
PROC_SPAWN 0 "worker" [1] -- Spawn worker with arg from r1
PROC_SEND 0 2             -- Send message from r2 to worker
PROC_RECEIVE 3            -- Block until message received into r3
```

## Determinism Checklist
When generating FinVM programs, ensure:
1. **No External IO**: Use `EFFECT_REQUEST` for side effects.
2. **Deterministic Time**: Use `logicalTick` or counts, never wall-clock.
3. **Canonical Order**: Map and Record iteration is sorted by keys; replay hashes use SHA-256 over canonical values.
4. **Validation**: All registers must be within `registerCount`.

## Optimization Tips
- **Register Pre-allocation**: Accessing a register is $O(1)$. Use them freely.
- **Tail Calls**: Use `TAIL_CALL` for recursion to avoid stack depth limits.
- **Sliced Execution**: The VM yields every 100 instructions by default.
