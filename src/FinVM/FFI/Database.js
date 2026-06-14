// Web Crypto (AES-GCM, PBKDF2, getRandomValues) — available as a global in both
// the browser and Node >= 20, so this module is portable with no node:crypto import.
const crypto = globalThis.crypto;

// Pure-JS SHA-256 (sync, no node:crypto) so db.hash works identically in Node and
// the browser. Output matches createHash("sha256").update(s,"utf8").digest("hex").
const SHA256_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);
function sha256Hex(str) {
  const rotr = (x, n) => (x >>> n) | (x << (32 - n));
  const data = new TextEncoder().encode(str);
  const l = data.length, bitLen = l * 8, withOne = l + 1;
  const k = (56 - (withOne % 64) + 64) % 64;
  const total = withOne + k + 8;
  const m = new Uint8Array(total);
  m.set(data); m[l] = 0x80;
  const dv = new DataView(m.buffer);
  dv.setUint32(total - 4, bitLen >>> 0, false);
  dv.setUint32(total - 8, Math.floor(bitLen / 0x100000000), false);
  let h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  let h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
  const w = new Uint32Array(64);
  for (let off = 0; off < total; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getUint32(off + i * 4, false);
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
    }
    let a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (let i = 0; i < 64; i++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (h + S1 + ch + SHA256_K[i] + w[i]) | 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) | 0;
      h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
    }
    h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0;
    h4 = (h4 + e) | 0; h5 = (h5 + f) | 0; h6 = (h6 + g) | 0; h7 = (h7 + h) | 0;
  }
  const hx = (x) => ("0000000" + (x >>> 0).toString(16)).slice(-8);
  return hx(h0) + hx(h1) + hx(h2) + hx(h3) + hx(h4) + hx(h5) + hx(h6) + hx(h7);
}

// PBKDF2 parameters for deriving the AES-GCM key from a passphrase.
const PBKDF2_ITERATIONS = 210000; // OWASP-recommended floor for PBKDF2-HMAC-SHA256
const KEY_LENGTH_BITS = 256;
const SALT_BYTES = 16;

// Keys that must never be honored as query fields — guards against prototype
// pollution / prototype-chain access via crafted query objects (e.g. from
// JSON.parse, which creates an own "__proto__" property).
const DANGEROUS_KEYS = new Set(['__proto__', 'constructor', 'prototype']);
const KNOWN_OPERATORS = new Set(['$gt', '$lt', '$eq']);

function safeFieldKeys(obj) {
    return Object.keys(obj).filter(k => !DANGEROUS_KEYS.has(k));
}

// Recursively serialize a value to canonical JSON with object keys sorted, so
// the table hash is independent of key insertion order (matching the SHA-256
// canonical hashing used elsewhere in FinVM).
function canonicalJSON(value) {
    if (value === null || typeof value !== 'object') return JSON.stringify(value);
    if (Array.isArray(value)) return '[' + value.map(canonicalJSON).join(',') + ']';
    const keys = Object.keys(value).sort();
    return '{' + keys.map(k => JSON.stringify(k) + ':' + canonicalJSON(value[k])).join(',') + '}';
}

/**
 * FinVM Secure Universal Database (FFI)
 * Provides encrypted, indexed, and deterministic storage.
 * Operations are purely in-memory (synchronous) for VM speed.
 * Persistence is handled explicitly via commit() to allow bulk operations.
 */
export class FinVMDatabase {
    constructor() {
        this.tables = new Map(); // table -> Map<id, Record>
        this.indices = new Map(); // table -> field -> value -> Set(ids)
        this.passphrase = null;   // raw passphrase; the AES key is derived per-commit
        this.salt = null;         // per-database PBKDF2 salt (persisted in the bundle)
        this.sequence = 0;
        this.isNode = typeof process !== 'undefined' && process.versions && process.versions.node;
        this.isBrowser = typeof window !== 'undefined' && typeof window.localStorage !== 'undefined';
    }

    // Store the passphrase. The AES-GCM key is NOT the raw passphrase: it is
    // derived with PBKDF2-HMAC-SHA256 using a per-database random salt (created
    // on first commit and persisted in plaintext in the bundle, then re-read on
    // load). This stretches weak/short passphrases and gives a full-length key.
    async setKey(keyString) {
        this.passphrase = keyString;
        this.salt = null;
    }

    async _deriveKey(salt) {
        const encoder = new TextEncoder();
        const baseKey = await crypto.subtle.importKey(
            'raw',
            encoder.encode(this.passphrase),
            { name: 'PBKDF2' },
            false,
            ['deriveKey']
        );
        return crypto.subtle.deriveKey(
            { name: 'PBKDF2', salt, iterations: PBKDF2_ITERATIONS, hash: 'SHA-256' },
            baseKey,
            { name: 'AES-GCM', length: KEY_LENGTH_BITS },
            false,
            ['encrypt', 'decrypt']
        );
    }

    createIndex(table, field) {
        if (!this.indices.has(table)) this.indices.set(table, new Map());
        if (!this.indices.get(table).has(field)) {
            const indexMap = new Map();
            this.indices.get(table).set(field, indexMap);

            // Backfill
            const tableMap = this.tables.get(table);
            if (tableMap) {
                for (const record of tableMap.values()) {
                    this._addToIndex(table, field, record.id, record.content);
                }
            }
        }
    }

    _addToIndex(table, field, id, content) {
        const tableIndices = this.indices.get(table);
        if (!tableIndices || !content || typeof content !== 'object') return;

        const indexMap = tableIndices.get(field);
        if (!indexMap) return;

        const val = content[field];
        if (val !== undefined && val !== null) {
            if (!indexMap.has(val)) indexMap.set(val, new Set());
            indexMap.get(val).add(id);
        }
    }

    _removeFromIndex(table, field, id, content) {
        const tableIndices = this.indices.get(table);
        if (!tableIndices || !content || typeof content !== 'object') return;

        const indexMap = tableIndices.get(field);
        if (!indexMap) return;

        const val = content[field];
        if (val !== undefined && val !== null && indexMap.has(val)) {
            const set = indexMap.get(val);
            set.delete(id);
            if (set.size === 0) indexMap.delete(val);
        }
    }

    insert(table, value) {
        if (!this.tables.has(table)) this.tables.set(table, new Map());
        
        const id = `rec${this.sequence}`;
        const timestamp = this.sequence;
        this.sequence += 1;
        const record = {
            id: id,
            timestamp,
            content: value
        };

        this.tables.get(table).set(id, record);
        
        const tableIndices = this.indices.get(table);
        if (tableIndices) {
            for (const field of tableIndices.keys()) {
                this._addToIndex(table, field, id, value);
            }
        }
        return id;
    }

    get(table, id) {
        const tableMap = this.tables.get(table);
        return tableMap ? (tableMap.get(id) || null) : null;
    }

    update(table, id, newValue) {
        const tableMap = this.tables.get(table);
        if (!tableMap || !tableMap.has(id)) return false;

        const record = tableMap.get(id);
        
        // Remove old indexed values
        const tableIndices = this.indices.get(table);
        if (tableIndices) {
            for (const field of tableIndices.keys()) {
                this._removeFromIndex(table, field, id, record.content);
            }
        }

        record.content = newValue;
        record.updatedAt = this.sequence;
        this.sequence += 1;

        // Add new indexed values
        if (tableIndices) {
            for (const field of tableIndices.keys()) {
                this._addToIndex(table, field, id, newValue);
            }
        }
        return true;
    }

    delete(table, id) {
        const tableMap = this.tables.get(table);
        if (!tableMap || !tableMap.has(id)) return false;

        const record = tableMap.get(id);
        
        // Remove from indices
        const tableIndices = this.indices.get(table);
        if (tableIndices) {
            for (const field of tableIndices.keys()) {
                this._removeFromIndex(table, field, id, record.content);
            }
        }

        tableMap.delete(id);
        return true;
    }

    query(table, mongoQuery, options = {}) {
        const tableMap = this.tables.get(table);
        if (!tableMap || tableMap.size === 0) return [];

        let candidateIds = null;
        const tableIndices = this.indices.get(table);

        // 1. Index Resolution Phase (O(1) lookups)
        if (tableIndices && mongoQuery && safeFieldKeys(mongoQuery).length > 0) {
            for (const field of safeFieldKeys(mongoQuery)) {
                if (tableIndices.has(field)) {
                    const condition = mongoQuery[field];
                    let exactValue = undefined;

                    if (typeof condition === 'object' && condition !== null) {
                        if (condition['$eq'] !== undefined) exactValue = condition['$eq'];
                    } else {
                        exactValue = condition;
                    }

                    if (exactValue !== undefined) {
                        const indexMap = tableIndices.get(field);
                        const matchingIds = indexMap.get(exactValue) || new Set();

                        if (candidateIds === null) {
                            candidateIds = new Set(matchingIds);
                        } else {
                            // Intersect sets
                            const intersection = new Set();
                            for (const id of candidateIds) {
                                if (matchingIds.has(id)) intersection.add(id);
                            }
                            candidateIds = intersection;
                        }
                    }
                }
            }
        }

        // 2. Filter Phase
        let filtered = [];
        if (candidateIds !== null) {
            // Fast path: Only check candidates found via indices
            for (const id of candidateIds) {
                const row = tableMap.get(id);
                if (this._match(row.content, mongoQuery)) {
                    filtered.push(row);
                }
            }
        } else {
            // Slow path: Full table scan
            for (const row of tableMap.values()) {
                if (this._match(row.content, mongoQuery)) {
                    filtered.push(row);
                }
            }
        }

        // 3. Sort Phase
        if (options.sort) {
            const { field, order } = options.sort;
            filtered.sort((a, b) => {
                const valA = a.content[field];
                const valB = b.content[field];
                const cmp = valA < valB ? -1 : valA > valB ? 1 : 0;
                return order === 'ASC' ? cmp : -cmp;
            });
        }
        return filtered;
    }

    _match(content, query) {
        if (!query || safeFieldKeys(query).length === 0) return true;
        if (!content || typeof content !== 'object') return false;

        return safeFieldKeys(query).every(field => {
            const condition = query[field];
            // Only read own properties of the record to avoid traversing the
            // prototype chain.
            const value = Object.prototype.hasOwnProperty.call(content, field) ? content[field] : undefined;
            if (typeof condition === 'object' && condition !== null) {
                // Treat as an operator object only for recognized operators.
                if (KNOWN_OPERATORS.has('$gt') && condition['$gt'] !== undefined && !(value > condition['$gt'])) return false;
                if (KNOWN_OPERATORS.has('$lt') && condition['$lt'] !== undefined && !(value < condition['$lt'])) return false;
                if (KNOWN_OPERATORS.has('$eq') && condition['$eq'] !== undefined && !(value === condition['$eq'])) return false;
                return true;
            }
            return value === condition;
        });
    }

    hashTable(table) {
        const tableMap = this.tables.get(table);
        if (!tableMap) return "0";
        
        // Deterministic, order-independent table digest: sort rows by id and
        // canonicalize each row (sorted keys), then SHA-256. This matches the
        // cryptographic hashing used elsewhere in FinVM and is collision-safe,
        // unlike the previous 32-bit rolling hash.
        const rows = Array.from(tableMap.values())
            .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
        const canonical = canonicalJSON(rows);
        return sha256Hex(canonical);
    }

    // Produce the portable, encrypted bundle STRING (AES-256-GCM + PBKDF2 salt).
    // This is the unit of movement: identical in the browser and Node, so a
    // bundle made in one can be decrypted in the other with the same passphrase.
    // Returns null when no passphrase is set.
    async exportEncrypted() {
        if (this.passphrase == null) return null;
        if (!this.salt) this.salt = crypto.getRandomValues(new Uint8Array(SALT_BYTES));
        const key = await this._deriveKey(this.salt);

        const serializableTables = Array.from(this.tables.entries()).map(([tName, tMap]) => {
            return [tName, Array.from(tMap.entries())];
        });
        const data = JSON.stringify({ sequence: this.sequence, tables: serializableTables });
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const encrypted = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, new TextEncoder().encode(data));

        return JSON.stringify({
            v: 2,
            salt: Array.from(this.salt),
            iv: Array.from(iv),
            data: Array.from(new Uint8Array(encrypted)),
        });
    }

    // Restore state from a portable encrypted bundle STRING (from exportEncrypted,
    // commit, localStorage, a file, or the cloud — they are all the same format).
    // Decrypts with the currently-set passphrase; a wrong passphrase throws (GCM).
    async importEncrypted(serialized) {
        if (!serialized || this.passphrase == null) return;
        const bundle = JSON.parse(serialized);
        if (!bundle.salt) throw new Error("Unsupported FinVM DB bundle: missing key-derivation salt");

        this.salt = new Uint8Array(bundle.salt);
        const key = await this._deriveKey(this.salt);
        const decrypted = await crypto.subtle.decrypt(
            { name: 'AES-GCM', iv: new Uint8Array(bundle.iv) }, key, new Uint8Array(bundle.data));

        const parsed = JSON.parse(new TextDecoder().decode(decrypted));
        const parsedTables = Array.isArray(parsed) ? parsed : parsed.tables;
        this.sequence = Array.isArray(parsed) ? 0 : parsed.sequence;

        this.tables = new Map();
        for (const [tName, entries] of parsedTables) this.tables.set(tName, new Map(entries));

        // Rebuild indices
        for (const [tName, tIndices] of this.indices.entries()) {
            for (const field of tIndices.keys()) {
                this.indices.get(tName).set(field, new Map());
                const tableMap = this.tables.get(tName);
                if (tableMap) for (const record of tableMap.values()) this._addToIndex(tName, field, record.id, record.content);
            }
        }
    }

    // Persist the bundle to the environment's default store: localStorage in the
    // browser, a .finvm.db file in Node. (Same bytes as exportEncrypted.)
    async commit() {
        const serialized = await this.exportEncrypted();
        if (serialized == null) return;
        if (this.isBrowser) {
            localStorage.setItem('finvm_db_enc', serialized);
        } else if (this.isNode) {
            try {
                const fs = await import('node:fs/promises');
                await fs.writeFile('.finvm.db', serialized);
            } catch (e) {
                console.error("Failed to commit DB:", e);
            }
        }
    }

    async load() {
        let serialized = null;
        if (this.isBrowser) {
            serialized = localStorage.getItem('finvm_db_enc');
        } else if (this.isNode) {
            try {
                const fs = await import('node:fs/promises');
                serialized = await fs.readFile('.finvm.db', 'utf8');
            } catch (e) {
                return;
            }
        }
        await this.importEncrypted(serialized);
    }
}

export const nativeDb = new FinVMDatabase();
