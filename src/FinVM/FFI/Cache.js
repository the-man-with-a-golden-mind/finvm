/**
 * FinVM High-Speed Key-Value Cache (FFI)
 * Pure JS, zero dependencies, no hashing.
 * Designed for maximum throughput.
 */
class FinVMCache {
    constructor() {
        // namespace -> Map<key, value>
        this.namespaces = new Map();
    }

    set(namespace, key, value) {
        let ns = this.namespaces.get(namespace);
        if (!ns) {
            ns = new Map();
            this.namespaces.set(namespace, ns);
        }
        ns.set(key, value);
        return true;
    }

    get(namespace, key) {
        const ns = this.namespaces.get(namespace);
        return ns ? (ns.get(key) || null) : null;
    }

    delete(namespace, key) {
        const ns = this.namespaces.get(namespace);
        if (!ns) return false;
        return ns.delete(key);
    }

    clear(namespace) {
        return this.namespaces.delete(namespace);
    }
}

export const nativeCache = new FinVMCache();
