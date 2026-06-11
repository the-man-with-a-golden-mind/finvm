# FinVM Built-in Database (Mnesia-Lite)

FinVM includes a high-performance, searchable database accessible via FFI. It allows processes to store complex VM objects and query them using deterministic rules.

## Core Features
- **Object Serialization**: Any VM `Value` (Records, Lists, BigInts) can be stored directly.
- **Searchable**: Stored objects are searchable via JS predicates.
- **Fast FFI**: Backed by optimized JavaScript storage.
- **Deterministic Metadata**: Record IDs and timestamp fields are generated from an internal sequence counter.

## API (Builtins)

### `db.insert(table, data)`
Inserts a VM value into the specified table.
- **Arguments**: `(Table: String, Data: Value)`
- **Returns**: `String` (A unique Record ID)

### `db.get(table, id)`
Retrieves a record by its unique ID.
- **Arguments**: `(Table: String, ID: String)`
- **Returns**: `Record { id: String, timestamp: Int, content: Value }`

### `db.query(table, query, options)`
Returns records matching MongoDB-style query parameters.
- **Arguments**: `(Table: String, Query: Record, Options: Record)`
- **Returns**: `List Record`

## Bytecode Example
```text
LOAD_CONST 0 "users"
RECORD_NEW 1
RECORD_SET 1 1 "name" 2 -- r2 has "Alice"
CALL_BUILTIN 3 "db.insert@1" [0, 1] -- r3 receives user_id
```

## Internal Serialization
When a VM object is stored, it is processed via the **Canonical Encoder**. This ensures that the same logical object always produces the same searchable string representation.

## Encryption & Key Derivation
Persistence (`commit`/`load`) encrypts the entire store with **AES-256-GCM**. The key is **not** the raw passphrase: it is derived with **PBKDF2-HMAC-SHA256** (210,000 iterations) using a per-database random 16-byte salt that is generated on first commit and stored, in plaintext, alongside the IV and ciphertext in the bundle. On load the salt is read back and the key re-derived, so the same passphrase decrypts the store while short/weak passphrases are stretched to a full 256-bit key. GCM provides authentication, so a wrong passphrase fails to decrypt rather than returning garbage.

> Note: the salt is per-database but stored with the ciphertext (necessary to re-derive the key). This defeats precomputed rainbow tables but does not protect against a targeted brute force of a weak passphrase — choose a strong passphrase.

## Deterministic Table Hash (`db.hash`)
`db.hash(table)` returns a **SHA-256** hex digest computed over the table's rows sorted by id and canonicalized with sorted keys. It is therefore stable across runs and independent of record key-insertion order, and is collision-resistant — suitable for proof-of-state checks.

## Cache vs. Determinism
The Cache FFI (`cache.*`) is an **in-memory, non-persisted performance aid**. Unlike the database (whose contents flow through canonical encoding) the cache is host-side mutable state that is **not** part of the VM state, snapshot, or replay hash (see `FinVM.Encoding.Snapshot`). Consequently:

- Cache contents must **never** influence a program's logical output. Treat the cache as a memoization layer only; a cold cache and a warm cache must produce identical results.
- Because it is excluded from snapshots, replaying a program reconstructs identical state/output hashes regardless of cache state, preserving FinVM's determinism guarantee.
