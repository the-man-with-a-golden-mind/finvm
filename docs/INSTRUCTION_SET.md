# FinVM Instruction Set

FinVM is a register-based VM. Instructions operate on registers (integer indexes) or immediate values.

## Control Flow
- `NOOP`: No operation.
- `HALT dst`: Stops the current process and sets the return value from `dst`.
- `ABORT code`: Fails the process with an error code.
- `LABEL name`: A no-op label for jumps.
- `JUMP label`: Unconditional jump.
- `JUMP_IF reg label`: Jump if `reg` contains `true`.
- `JUMP_IF_FALSE reg label`: Jump if `reg` contains `false`.
- `CALL dst fn [args...]`: Calls a function. `dst` receives the result.
- `TAIL_CALL fn [args...]`: Optimized tail call.
- `RETURN src`: Returns value from `src` to the caller.

## Data Movement
- `MOVE dst src`: Copy value from `src` to `dst`.
- `LOAD_CONST dst idx`: Load constant at index `idx` from the program's constant pool.
- `LOAD_INPUT dst path`: Read a value from VM input.
- `LOAD_CONTEXT dst path`: Read deterministic execution context.
- `CLEAR dst`: Resets `dst` to `VUnit`.

## Numeric Operations
- `ADD dst a b`: `dst = a + b`. Supports `BigInt` and `Fixed`.
- `SUB dst a b`: `dst = a - b`.
- `MUL dst a b`: `dst = a * b`.
- `DIV dst rounding a b`: `dst = a / b` with specified rounding mode.
- `MOD dst a b`: `dst = a % b`.
- `NEG dst src`: `dst = -src`.
- `ABS dst src`: Absolute value.
- `GT`, `GTE`, `LT`, `LTE`, `EQ`, `NEQ`: Standard comparisons.
- `COMPARE dst a b`: Stores ordering as `-1`, `0`, or `1`.

## Collections
- `RECORD_NEW dst`: Create empty record.
- `RECORD_GET dst rec field`: Read field.
- `RECORD_GET_OPT dst rec field`: Read optional field as `VOption`.
- `RECORD_SET dst rec field val`: Update/add field (returns new record).
- `RECORD_HAS`, `RECORD_REMOVE`, `RECORD_KEYS`: Field membership, removal, and sorted keys.
- `LIST_NEW dst`: Create empty list.
- `LIST_FROM dst [regs...]`: Build a list from registers.
- `LIST_APPEND dst list val`: Append item (returns new list).
- `LIST_GET dst list idx`: Read at index.
- `LIST_SET`, `LIST_LENGTH`, `LIST_SLICE`: Indexed update, length, and slicing.
- `MAP_NEW`, `MAP_GET`, `MAP_GET_OPT`, `MAP_SET`, `MAP_HAS`, `MAP_REMOVE`, `MAP_KEYS`, `MAP_VALUES`, `MAP_SIZE`: Deterministic map operations.
- `VARIANT_NEW`, `VARIANT_TAG`, `VARIANT_PAYLOAD`: Tagged union construction and inspection.

## State Management
- `STATE_GET dst path`: Read from global VM state.
- `STATE_GET_OPT dst path`: Optional state read as `VOption`.
- `STATE_SET path src`: Write to global VM state.
- `STATE_DELETE path`: Remove key.
- `STATE_EXISTS`, `STATE_KEYS`, `STATE_SNAPSHOT`: State membership, key listing, and canonical snapshot capture.

## Events & Effects
- `EVENT_NEW`, `EVENT_EMIT`, `EVENT_BATCH_NEW`, `EVENT_BATCH_APPEND`: Deterministic event creation and emission.
- `EFFECT_NEW`, `EFFECT_REQUEST`, `EFFECT_BATCH_NEW`, `EFFECT_BATCH_APPEND`: Create side-effect intents for host execution.

## Process Management (Erlang-like)
- `PROC_SELF dst`: Get current process PID.
- `PROC_SPAWN dst fn [args...]`: Start new process.
- `PROC_SEND pid msg`: Send message to process mailbox.
- `PROC_RECEIVE dst`: Read oldest message or block.
- `PROC_RECEIVE_MATCH dst tagReg`: Scan mailbox in order for first `VVariant` whose tag equals string in `tagReg`; remove only that message, otherwise block on `WaitingOnMatch tag`.
- `PROC_RECEIVE_MATCH_OPT dst tagReg`: Non-blocking selective receive. Returns `VOption (Just msg)` when match exists, otherwise `VOption Nothing`.
- `PROC_YIELD`: Voluntarily give up execution slice.
- `PROC_JOIN`, `PROC_JOIN_RESULT`, `PROC_STATUS`, `PROC_CANCEL`, `PROC_EXIT`: Lifecycle coordination.
- `PROC_LINK`, `PROC_UNLINK`, `PROC_MONITOR`, `PROC_DEMONITOR`, `PROC_TRAP_EXIT`, `PROC_SLEEP_TICKS`: Erlang-style supervision metadata and logical-tick sleeps.

## Nodes & Remote Processes
- `NODE_SELF`, `NODE_STATUS`, `NODE_KNOWN`: Deterministic local node metadata.
- `REMOTE_PID_NEW`, `REMOTE_PID_NODE`, `REMOTE_PID_LOCAL`: Remote PID value construction and inspection.
- `NODE_SEND`, `NODE_SPAWN`, `NODE_MONITOR`, `NODE_DEMONITOR`, `NODE_QUERY_STATE`: Remote operations represented as effect intents.
- `NODE_OBSERVE_STATE`, `NODE_LAST_STATE_HASH`, `NODE_LAST_SEEN_TICK`: Local observations of remote-node metadata.

## State Machines
- `MACHINE_NEW dst smId data`: Create machine instance.
- `MACHINE_TRANSITION dst instance event`: Trigger transition.
- `MACHINE_STATE dst instance`: Get current state name.

## Proving & Debugging
- `ASSERT reg code`: Fail if `reg` is false, record in proof trace.
- `ASSUME reg note`: Record assumption in proof trace.
- `INVARIANT_CHECK fn`: Execute invariant function and record the result.
- `PROOF_MARK label reg`: Record value with label in proof trace.
- `PROOF_SCOPE_BEGIN`, `PROOF_SCOPE_END`: Mark proof trace scopes.
