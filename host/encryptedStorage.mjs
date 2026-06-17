// Encrypted DB storage for effect handlers — plaintext only inside FinVMDatabase;
// sync/persist egress is opaque fenc ciphertext only.

import { FinVMDatabase } from '../src/FinVM/FFI/Database.js';
import { sealForPersist } from '../src/FinVM/FFI/SecureLoader.js';

/**
 * Storage backend backed by FinVMDatabase + project DEK.
 * Handlers operate on plaintext records in-memory; export/commit returns ciphertext only.
 */
export function createEncryptedDbStorage(dek, { initialDbBlob = null, persistence = null } = {}) {
  const db = new FinVMDatabase(persistence ? { persistence } : {});
  let ready = false;

  async function ensureReady() {
    if (!ready) {
      await db.setDEK(dek);
      if (initialDbBlob) {
        await db.importEncrypted(initialDbBlob);
      }
      ready = true;
    }
  }

  return {
    async dbInsert(table, record) {
      await ensureReady();
      return db.insert(table, record);
    },
    async dbGet(table, id) {
      await ensureReady();
      return db.get(table, id);
    },
    async dbUpdate(table, id, record) {
      await ensureReady();
      return db.update(table, id, record);
    },
    async dbDelete(table, id) {
      await ensureReady();
      return db.delete(table, id);
    },
    async cacheSet(_ns, _key, _value) {
      throw new Error('cache not persisted in encrypted DB storage');
    },
    async cacheGet() { return null; },
    async cacheDelete() { return false; },
    /** Opaque ciphertext bundle for platform sync — no plaintext fields. */
    async exportCiphertext() {
      await ensureReady();
      return db.exportEncrypted();
    },
    async importCiphertext(blob) {
      await ensureReady();
      await db.importEncrypted(blob);
    },
    async commit() {
      await ensureReady();
      await db.commit();
      return db.exportEncrypted();
    },
    async sealOutput(payload) {
      await ensureReady();
      const text = typeof payload === 'string' ? payload : JSON.stringify(payload);
      return sealForPersist(dek, 'output', text);
    },
    async load() {
      await ensureReady();
      await db.load();
    },
    hashTable(table) {
      return db.hashTable(table);
    },
  };
}

/** Seal VM output for ciphertext-only platform egress (target: output). */
export async function sealOutputPayload(dek, payload) {
  const text = typeof payload === 'string' ? payload : JSON.stringify(payload);
  return sealForPersist(dek, 'output', text);
}

/** @deprecated Use sealOutputPayload */
export const sealSyncPayload = sealOutputPayload;
