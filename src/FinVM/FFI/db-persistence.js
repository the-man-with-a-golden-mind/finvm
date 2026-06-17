// Pluggable encrypted DB persistence backends (IndexedDB, file, localStorage fallback).

export const IDB_NAME = 'finvm_db';
export const IDB_STORE = 'kv';
export const IDB_KEY = 'encrypted_bundle';

export function createIndexedDbPersistence({
  dbName = IDB_NAME,
  storeName = IDB_STORE,
  key = IDB_KEY,
} = {}) {
  function openDb() {
    return new Promise((resolve, reject) => {
      if (typeof indexedDB === 'undefined') {
        reject(new Error('IndexedDB unavailable'));
        return;
      }
      const req = indexedDB.open(dbName, 1);
      req.onupgradeneeded = () => {
        if (!req.result.objectStoreNames.contains(storeName)) {
          req.result.createObjectStore(storeName);
        }
      };
      req.onerror = () => reject(req.error ?? new Error('IndexedDB open failed'));
      req.onsuccess = () => resolve(req.result);
    });
  }

  return {
    kind: 'indexeddb',
    async read() {
      const db = await openDb();
      return new Promise((resolve, reject) => {
        const tx = db.transaction(storeName, 'readonly');
        const get = tx.objectStore(storeName).get(key);
        get.onerror = () => reject(get.error ?? new Error('IndexedDB read failed'));
        get.onsuccess = () => resolve(get.result ?? null);
        tx.oncomplete = () => db.close();
        tx.onerror = () => {
          db.close();
          reject(tx.error ?? new Error('IndexedDB read transaction failed'));
        };
      });
    },
    async write(serialized) {
      const db = await openDb();
      return new Promise((resolve, reject) => {
        const tx = db.transaction(storeName, 'readwrite');
        tx.objectStore(storeName).put(serialized, key);
        tx.oncomplete = () => {
          db.close();
          resolve();
        };
        tx.onerror = () => {
          db.close();
          reject(tx.error ?? new Error('IndexedDB write failed'));
        };
      });
    },
  };
}

export function createFilePersistence(path = '.finvm.db') {
  return {
    kind: 'file',
    async read() {
      const fs = await import('node:fs/promises');
      try {
        return await fs.readFile(path, 'utf8');
      } catch (e) {
        if (e?.code === 'ENOENT') return null;
        throw e;
      }
    },
    async write(serialized) {
      const fs = await import('node:fs/promises');
      await fs.writeFile(path, serialized);
    },
  };
}

export function createLocalStoragePersistence(storageKey = 'finvm_db_enc') {
  return {
    kind: 'localStorage',
    async read() {
      if (typeof globalThis.localStorage === 'undefined') return null;
      return globalThis.localStorage.getItem(storageKey);
    },
    async write(serialized) {
      if (typeof globalThis.localStorage === 'undefined') {
        throw new Error('localStorage unavailable');
      }
      globalThis.localStorage.setItem(storageKey, serialized);
    },
  };
}

/** Default backend for the current runtime (Node file, browser IndexedDB, localStorage fallback). */
export function createDefaultPersistence({ isNode, isBrowser } = {}) {
  const node = isNode ?? (typeof process !== 'undefined' && process.versions?.node);
  if (node) return createFilePersistence('.finvm.db');
  const browser = isBrowser ?? (typeof globalThis.window !== 'undefined' || typeof indexedDB !== 'undefined');
  if (browser && typeof indexedDB !== 'undefined') return createIndexedDbPersistence();
  if (typeof globalThis.localStorage !== 'undefined') return createLocalStoragePersistence();
  return {
    kind: 'memory',
    async read() { return null; },
    async write() {},
  };
}
