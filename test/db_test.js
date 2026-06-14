import { FinVMDatabase } from '../src/FinVM/FFI/Database.js';
import * as fs from 'node:fs/promises';
import assert from 'node:assert';

async function runTests() {
    console.log("Starting DB Security & Feature Tests...");
    const dbFile = '.finvm.db';

    // Cleanup before tests
    try { await fs.unlink(dbFile); } catch (e) {}

    // Test 1: Basic In-Memory Operations
    console.log("1. Testing Basic Operations & Queries...");
    const db1 = new FinVMDatabase();
    
    const id1 = await db1.insert("users", { name: "Alice", age: 30, role: "admin" });
    const id2 = await db1.insert("users", { name: "Bob", age: 25, role: "user" });
    const id3 = await db1.insert("users", { name: "Charlie", age: 35, role: "user" });

    assert.ok(id1 && id2 && id3, "IDs should be generated");
    
    // Get
    const alice = db1.get("users", id1);
    assert.strictEqual(alice.content.name, "Alice");

    // Query $eq
    const admins = db1.query("users", { role: { $eq: "admin" } });
    assert.strictEqual(admins.length, 1);
    assert.strictEqual(admins[0].content.name, "Alice");

    // Query $gt, $lt and Sorting
    const over25 = db1.query("users", { age: { $gt: 25 } }, { sort: { field: "age", order: "ASC" } });
    assert.strictEqual(over25.length, 2);
    assert.strictEqual(over25[0].content.name, "Alice"); // age 30
    assert.strictEqual(over25[1].content.name, "Charlie"); // age 35

    // Query hardening: dangerous keys must be ignored, never pollute prototypes
    const malicious = JSON.parse('{"__proto__": {"polluted": true}, "role": {"$eq": "admin"}}');
    const guarded = db1.query("users", malicious);
    assert.strictEqual({}.polluted, undefined, "Prototype must not be polluted by a query");
    // The dangerous key is dropped; the legitimate role filter still applies
    assert.strictEqual(guarded.length, 1, "Query must honor only safe fields");
    assert.strictEqual(guarded[0].content.name, "Alice");

    // Test 2: Indexing
    console.log("2. Testing Indices...");
    db1.createIndex("users", "role");
    await db1.insert("users", { name: "Dave", age: 40, role: "admin" });
    assert.ok(db1.indices.get("users").get("role").has("admin"));
    assert.strictEqual(db1.indices.get("users").get("role").get("admin").size, 2);

    // Test 3: Deterministic Hashing
    console.log("3. Testing Deterministic Hashing...");
    const hash1 = db1.hashTable("users");
    // Ensure hash is consistent
    const hash2 = db1.hashTable("users");
    assert.strictEqual(hash1, hash2, "Hash must be deterministic");
    // Must be a SHA-256 hex digest (64 lowercase hex chars), not the old 32-bit hash
    assert.ok(/^[0-9a-f]{64}$/.test(hash1), "Table hash must be a SHA-256 hex digest");

    // Hash must be independent of key insertion order within records (canonical)
    const dbA = new FinVMDatabase();
    const dbB = new FinVMDatabase();
    await dbA.insert("t", { a: 1, b: 2, c: 3 });
    await dbB.insert("t", { c: 3, b: 2, a: 1 });
    assert.strictEqual(dbA.hashTable("t"), dbB.hashTable("t"), "Hash must be canonical (key-order independent)");
    // Different content must produce a different hash
    const dbC = new FinVMDatabase();
    await dbC.insert("t", { a: 1, b: 2, c: 4 });
    assert.notStrictEqual(dbA.hashTable("t"), dbC.hashTable("t"), "Different data must hash differently");

    // Test 4: Security and Persistence (Encrypted)
    console.log("4. Testing Encryption & Persistence...");
    const db2 = new FinVMDatabase();
    await db2.setKey("super_secret_vm_key_123");
    await db2.insert("secrets", { info: "Top Secret Data" });
    await db2.commit();

    // File should exist now
    const fileContent = await fs.readFile(dbFile, 'utf8');
    const parsed = JSON.parse(fileContent);
    assert.ok(parsed.iv, "IV must exist in bundle");
    assert.ok(parsed.data, "Encrypted data must exist in bundle");
    assert.ok(parsed.salt && parsed.salt.length === 16, "Per-database PBKDF2 salt must be persisted in bundle");
    assert.ok(!fileContent.includes("Top Secret Data"), "File must not contain plaintext data");

    // Load with same key
    const db3 = new FinVMDatabase();
    await db3.setKey("super_secret_vm_key_123");
    await db3.load();
    const secrets = db3.query("secrets", {});
    assert.strictEqual(secrets.length, 1);
    assert.strictEqual(secrets[0].content.info, "Top Secret Data", "Should decrypt successfully");

    // Load with wrong key
    console.log("5. Testing Security Boundaries (Wrong Key)...");
    const db4 = new FinVMDatabase();
    await db4.setKey("wrong_key_entirely_0000000000000");
    try {
        await db4.load();
        assert.fail("Should have thrown an error on decryption failure");
    } catch (e) {
        assert.ok(e.message.includes("The operation failed") || e.message.includes("Unsupported state") || e.message.includes("decrypt"), "Decryption must fail with wrong key");
    }

    // Ensure no persistence without key
    console.log("6. Testing Persistence Without Key...");
    try { await fs.unlink(dbFile); } catch (e) {}
    const db5 = new FinVMDatabase();
    await db5.insert("public", { info: "Public Data" });
    await db5.commit();
    
    try {
        await fs.access(dbFile);
        assert.fail("File should not be created if no key is provided");
    } catch (e) {
        assert.strictEqual(e.code, 'ENOENT', "File must not exist");
    }

    // Test 7: Portable export/import (browser <-> cloud <-> node movement)
    // The encrypted bundle string is environment-agnostic (globalThis.crypto +
    // pure-JS SHA-256), so a DB exported in one place imports anywhere with the
    // same passphrase. Two independent instances stand in for two environments.
    console.log("7. Testing portable export/import (cross-environment movement)...");
    const origin = new FinVMDatabase();           // e.g. the browser
    await origin.setKey("portable_passphrase_xyz");
    origin.createIndex("accounts", "owner");
    await origin.insert("accounts", { owner: "alice", balance: 100 });
    await origin.insert("accounts", { owner: "bob", balance: 50 });
    const originHash = origin.hashTable("accounts");
    const blob = await origin.exportEncrypted();   // -> upload to the cloud
    assert.ok(typeof blob === "string" && blob.length > 0, "export produces a portable string");
    assert.ok(!blob.includes("alice"), "exported blob is encrypted (no plaintext)");

    const dest = new FinVMDatabase();              // e.g. the desktop
    await dest.setKey("portable_passphrase_xyz");
    await dest.importEncrypted(blob);              // <- download from the cloud
    const moved = dest.query("accounts", { owner: "alice" }, {});
    assert.strictEqual(moved.length, 1, "imported DB is queryable");
    assert.strictEqual(moved[0].content.balance, 100, "imported data intact");
    assert.strictEqual(dest.hashTable("accounts"), originHash, "db.hash identical after move (integrity)");

    // Wrong passphrase on import must fail (GCM auth)
    const intruder = new FinVMDatabase();
    await intruder.setKey("not_the_passphrase");
    try { await intruder.importEncrypted(blob); assert.fail("import with wrong key must throw"); }
    catch (e) { assert.ok(/operation failed|Unsupported state|decrypt/i.test(e.message), "wrong-key import rejected"); }

    // Cleanup
    try { await fs.unlink(dbFile); } catch (e) {}
    console.log("All DB Tests Passed Successfully! 🚀");
}

runTests().catch(err => {
    console.error("Test failed:", err);
    process.exit(1);
});
