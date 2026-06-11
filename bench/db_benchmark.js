import { FinVMDatabase } from '../src/FinVM/FFI/Database.js';
import * as fs from 'node:fs/promises';
import assert from 'node:assert';
import { performance } from 'node:perf_hooks';

async function runBenchmark() {
    console.log("Starting DB Benchmarks & Advanced Tests...");
    const dbFile = '.finvm.db';

    // Cleanup
    try { await fs.unlink(dbFile); } catch (e) {}

    const db = new FinVMDatabase();
    await db.setKey("benchmark_secret_key_1234567890");

    // 1. Bulk Insert
    const size = 10000;
    console.log(`\n--- 1. Bulk Insert (${size} records) ---`);
    
    // We create an index BEFORE inserting to measure insert time with index updates
    db.createIndex("users", "role");
    db.createIndex("users", "active");

    const startInsert = performance.now();
    const ids = [];
    for (let i = 0; i < size; i++) {
        // distribute roles: admin (10%), user (90%)
        const role = i % 10 === 0 ? "admin" : "user";
        // active: true (50%), false (50%)
        const active = i % 2 === 0;
        
        const id = db.insert("users", {
            name: `User_${i}`,
            age: 20 + (i % 40), // 20 to 59
            role: role,
            active: active,
            score: Math.random()
        });
        ids.push(id);
    }
    const endInsert = performance.now();
    console.log(`Inserted ${size} records in ${(endInsert - startInsert).toFixed(2)}ms`);

    // 2. Point Read (Read by ID)
    console.log(`\n--- 2. Point Read (10,000 random reads) ---`);
    const startRead = performance.now();
    for (let i = 0; i < size; i++) {
        // pick random ID
        const targetId = ids[Math.floor(Math.random() * size)];
        const record = db.get("users", targetId);
        assert.ok(record !== null);
    }
    const endRead = performance.now();
    console.log(`Read ${size} records by ID in ${(endRead - startRead).toFixed(2)}ms`);

    // 3. Unindexed Search
    console.log(`\n--- 3. Unindexed Search (Full Table Scan) ---`);
    const startScan = performance.now();
    // Search by age (not indexed)
    const over40 = db.query("users", { age: { $gt: 40 } });
    const endScan = performance.now();
    console.log(`Found ${over40.length} records without index in ${(endScan - startScan).toFixed(2)}ms`);

    // 4. Indexed Search
    console.log(`\n--- 4. Indexed Search (O(1) resolution) ---`);
    const startIdxScan = performance.now();
    // Search by role (indexed) and active (indexed)
    const activeAdmins = db.query("users", { role: "admin", active: true });
    const endIdxScan = performance.now();
    console.log(`Found ${activeAdmins.length} active admins using indices in ${(endIdxScan - startIdxScan).toFixed(2)}ms`);

    // 5. Update Record
    console.log(`\n--- 5. Update Operations ---`);
    const targetUpdateId = ids[0];
    const oldRecord = db.get("users", targetUpdateId);
    assert.strictEqual(oldRecord.content.role, "admin");

    const startUpdate = performance.now();
    db.update("users", targetUpdateId, { ...oldRecord.content, role: "superadmin" });
    const endUpdate = performance.now();
    
    const updatedRecord = db.get("users", targetUpdateId);
    assert.strictEqual(updatedRecord.content.role, "superadmin");
    // Verify index was updated
    const superAdmins = db.query("users", { role: "superadmin" });
    assert.strictEqual(superAdmins.length, 1);
    
    console.log(`Updated 1 record and indices in ${(endUpdate - startUpdate).toFixed(2)}ms`);

    // 6. Delete Record
    console.log(`\n--- 6. Delete Operations ---`);
    const startDelete = performance.now();
    db.delete("users", targetUpdateId);
    const endDelete = performance.now();
    
    const deletedRecord = db.get("users", targetUpdateId);
    assert.strictEqual(deletedRecord, null);
    // Verify index was updated
    const superAdminsAfterDelete = db.query("users", { role: "superadmin" });
    assert.strictEqual(superAdminsAfterDelete.length, 0);

    console.log(`Deleted 1 record and removed from indices in ${(endDelete - startDelete).toFixed(2)}ms`);

    // 7. Commit (Encryption & Persistence)
    console.log(`\n--- 7. Commit to Disk (AES-GCM Encryption) ---`);
    const startCommit = performance.now();
    await db.commit();
    const endCommit = performance.now();
    console.log(`Encrypted and serialized ${size - 1} records to disk in ${(endCommit - startCommit).toFixed(2)}ms`);

    // Cleanup
    try { await fs.unlink(dbFile); } catch (e) {}
    console.log("\nAll Benchmarks & Tests Completed Successfully! 🚀");
}

runBenchmark().catch(err => {
    console.error("Benchmark failed:", err);
    process.exit(1);
});
