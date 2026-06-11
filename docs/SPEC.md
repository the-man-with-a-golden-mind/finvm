# FinVM Architecture Specification

FinVM is a universal deterministic virtual machine implemented in PureScript. It is designed to be the foundational substrate for state machines, auditable workflows, and distributed systems.

## Core Design Principles

### 1. Determinism
FinVM guarantees that `Program + Input + State` always produces the exact same `NewState + Output + Trace`.
- **No Wall-Clock**: All time-based operations use logical ticks.
- **No Randomness**: Any entropy must be provided as explicit input.
- **Stable Collections**: Maps and Records are canonically sorted by keys.

### 2. Purity
The VM core is 100% pure. It never interacts with the filesystem, network, or OS.
- **Effect Intents**: Side effects are represented as data (Intents). The host environment executes these intents outside the VM.
- **Remote Intents**: Node and remote-process instructions create deterministic metadata or effect intents; transport is a host concern.

### 3. Lightweight Processes
Inspired by Erlang/BEAM, FinVM manages its own "processes".
- **Isolation**: Each process has its own registers and call stack.
- **Message Passing**: Processes communicate via mailboxes.
- **Scheduling**: A deterministic round-robin scheduler handles preemption using fixed time-slices.

## Execution Model

### Register-Based VM
Unlike stack VMs, FinVM uses a pre-allocated register bank for each function call. This enables $O(1)$ data access and easier debugging.

### Sliced Execution
To prevent long-running processes from blocking the VM, execution is sliced. Every 100 instructions, the scheduler saves the process state and picks the next one from the ready queue.

## Auditing and Verification

### Functional Snapshots
The entire machine state can be serialized into a canonical string and hashed with SHA-256 at any instruction boundary. This is the basis for:
- **Snapshots**: Save and restore execution.
- **Replay**: Verify previous executions by comparing expected state and output hashes.
- **State Hashing**: Reliable consensus in distributed environments.

### Proof Traces
Built-in `ASSERT` and `ASSUME` instructions allow programs to generate a cryptographic audit trail of their logic transitions.
