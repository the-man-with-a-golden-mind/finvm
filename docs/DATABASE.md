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

## Node / browser portability (100% compatible)
The DB is fully portable across backend and frontend, with byte-identical results:
- **SHA-256** (`db.hash`, and the VM's `hash.sha256`) is a pure-JS implementation — no `node:crypto`, synchronous, identical output in Node and the browser.
- **AES-256-GCM + PBKDF2** use `globalThis.crypto` (Web Crypto), available in browsers and Node ≥ 20. The encrypted bundle format (`{ v, salt, iv, data }`) is identical on both ends.
- **Persistence backend differs by environment** (browsers have no filesystem): the browser writes the encrypted bundle to `localStorage` (`finvm_db_enc`); Node writes the `.finvm.db` file via a dynamically-imported `node:fs/promises` (never loaded in the browser). The on-the-wire encrypted bytes are the same, so a store committed in one environment can be loaded in the other if the bytes are transferred.

## Moving a DB across environments (browser → cloud → desktop)
The encrypted bundle is a single portable string; move it however you like:
```js
// Browser: build, hash, export
await db.setKey(passphrase);
await db.insert("accounts", { owner: "alice", balance: 100 });
const hash = db.hashTable("accounts");      // record for integrity
const blob = await db.exportEncrypted();    // portable, encrypted string
// -> upload `blob` (and optionally `hash`) to the cloud

// Desktop (Node) later: download, import, verify
const db2 = new FinVMDatabase();
await db2.setKey(passphrase);               // same passphrase
await db2.importEncrypted(blob);            // restore state
assert(db2.hashTable("accounts") === hash); // same SHA-256 => intact
```
- `exportEncrypted()` → the AES-256-GCM bundle string (same bytes `commit()` would persist); `null` if no passphrase. `importEncrypted(blob)` decrypts with the set passphrase (wrong passphrase throws — GCM authentication).
- Because SHA-256 is pure-JS and AES/PBKDF2 use Web Crypto, the bundle and the `db.hash` are **byte-identical across browser and Node** — the move is lossless and verifiable. `commit()`/`load()` are just `exportEncrypted`/`importEncrypted` wired to the environment's default store.

## Cache vs. Determinism
The Cache FFI (`cache.*`) is an **in-memory, non-persisted performance aid**. Unlike the database (whose contents flow through canonical encoding) the cache is host-side mutable state that is **not** part of the VM state, snapshot, or replay hash (see `FinVM.Encoding.Snapshot`). Consequently:

- Cache contents must **never** influence a program's logical output. Treat the cache as a memoization layer only; a cold cache and a warm cache must produce identical results.
- Because it is excluded from snapshots, replaying a program reconstructs identical state/output hashes regardless of cache state, preserving FinVM's determinism guarantee.
