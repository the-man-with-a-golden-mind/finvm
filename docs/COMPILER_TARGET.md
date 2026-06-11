# FinVM Compiler Target Specification

This document is the definitive guide for AI models or developers building high-level languages that compile to FinVM.

## 1. Program Data Structure
A compiler must emit a `Program` object. While the implementation is in PureScript, the canonical exchange format is **JSON**.

### Schema
```json
{
  "version": "1.0",
  "registerCount": 5,
  "constants": [ {"int": "100"}, {"string": "Hello"} ],
  "instructions": [
    ["LOAD_CONST", 0, 0],
    ["RETURN", 0]
  ],
  "state": {},
  "input": {},
  "limits": { "maxSteps": 10000 }
}
```

The CLI also accepts the instructions and register count under `functions.main`:

```json
{
  "functions": {
    "main": {
      "registerCount": 5,
      "instructions": [
        ["LOAD_CONST", 0, 0],
        ["RETURN", 0]
      ]
    }
  }
}
```

Values use stable tagged JSON for non-primitive VM values: `{ "int": "42" }`, `{ "bool": true }`, `{ "string": "text" }`, `{ "list": [...] }`, `{ "record": { "field": value } }`, and `{ "variant": { "tag": "Some", "payload": value } }`.

## 2. ABI (Application Binary Interface)

### Function Calls
- **Registers 0 to (Arity - 1)**: Reserved for incoming arguments.
- **Return Value**: Passed via the `RETURN <reg>` instruction.
- **Caller Responsibilities**: The `CALL <dst> <fn> [<args...>]` instruction automatically maps the provided registers in the caller's frame to the first $N$ registers of the callee's frame.

### Memory Model
- FinVM is a **Register Machine**. Compilers should treat registers as "named slots" and perform **Register Allocation**.
- There is no global heap. All data is either in **Local Registers**, the **Global State** (`STATE_SET`), or **Process Mailboxes**.

## 3. High-Level Mapping Patterns

### Boolean Logic
Map high-level `if/else` to:
1. `EQ`, `LT`, etc. to populate a boolean register.
2. `JUMP_IF` to go to the `true_branch`.
3. `JUMP` to skip to the `end`.

### Collections
- **Records**: Use `RECORD_NEW`, `RECORD_SET`, and `RECORD_GET`. Ideal for objects and structs.
- **Lists**: Use `LIST_NEW` and `LIST_APPEND`. Ideal for arrays.
- **Maps**: Use `MAP_NEW` and `MAP_SET` for dictionary-like structures.

### Recursion
- Use `TAIL_CALL` for self-recursion. FinVM optimizes this to prevent stack overflow.

## 4. Error Handling
- Use `ABORT <code>` to trigger a deterministic failure.
- Invariants should be enforced using `ASSERT <reg> <code>`.

## 5. Builtin Signatures
Compilers can rely on these IDs being available:
- `bigint.add@1`, `bigint.mul@1`, `bigint.modPow@1`
- `hash.sha256@1`
- `logic.and@1`, `logic.or@1`, `logic.not@1`

## 6. Optimization Checklist for Compilers
1. **Dead Code Elimination**: Remove `LABEL`s that are never jumped to.
2. **Register Minimization**: Set `registerCount` to the minimum required to save memory.
3. **Purity**: Ensure no "hidden" state is assumed; use `STATE_GET` explicitly.
