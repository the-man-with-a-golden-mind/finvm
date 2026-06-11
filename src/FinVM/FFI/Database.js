import { webcrypto, createHash } from 'node:crypto';

const crypto = typeof window !== 'undefined' ? (window.crypto || window.msCrypto) : webcrypto;

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
        return createHash('sha256').update(canonical).digest('hex');
    }

    async commit() {
        if (this.passphrase == null) return;

        // Reuse the salt from a prior load; otherwise mint a fresh one.
        if (!this.salt) this.salt = crypto.getRandomValues(new Uint8Array(SALT_BYTES));
        const key = await this._deriveKey(this.salt);

        // Serialize Maps to Arrays for JSON
        const serializableTables = Array.from(this.tables.entries()).map(([tName, tMap]) => {
            return [tName, Array.from(tMap.entries())];
        });

        const data = JSON.stringify({ sequence: this.sequence, tables: serializableTables });
        const encoder = new TextEncoder();
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const encrypted = await crypto.subtle.encrypt(
            { name: 'AES-GCM', iv: iv },
            key,
            encoder.encode(data)
        );

        const bundle = {
            v: 2,
            salt: Array.from(this.salt),
            iv: Array.from(iv),
            data: Array.from(new Uint8Array(encrypted))
        };

        const serialized = JSON.stringify(bundle);
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

        if (!serialized || this.passphrase == null) return;

        const bundle = JSON.parse(serialized);
        if (!bundle.salt) {
            throw new Error("Unsupported FinVM DB bundle: missing key-derivation salt");
        }
        this.salt = new Uint8Array(bundle.salt);
        const key = await this._deriveKey(this.salt);
        const decrypted = await crypto.subtle.decrypt(
            { name: 'AES-GCM', iv: new Uint8Array(bundle.iv) },
            key,
            new Uint8Array(bundle.data)
        );

        const decoder = new TextDecoder();
        const parsed = JSON.parse(decoder.decode(decrypted));
        const parsedTables = Array.isArray(parsed) ? parsed : parsed.tables;
        this.sequence = Array.isArray(parsed) ? 0 : parsed.sequence;
        
        this.tables = new Map();
        for (const [tName, entries] of parsedTables) {
            this.tables.set(tName, new Map(entries));
        }

        // Rebuild indices
        for (const [tName, tIndices] of this.indices.entries()) {
            for (const field of tIndices.keys()) {
                this.indices.get(tName).set(field, new Map()); // Clear index
                const tableMap = this.tables.get(tName);
                if (tableMap) {
                    for (const record of tableMap.values()) {
                        this._addToIndex(tName, field, record.id, record.content);
                    }
                }
            }
        }
    }
}

export const nativeDb = new FinVMDatabase();
