import { FinVMDatabase } from '../src/FinVM/FFI/Database.js';
import { performance } from 'node:perf_hooks';

async function runQueryBenchmarks() {
    console.log("Starting DB Query Performance Benchmarks...");
    const db = new FinVMDatabase();

    const size = 100000; // 100k records for a solid test
    console.log(`\nPreparing database with ${size} records...`);
    
    // Create indices
    db.createIndex("users", "role");
    db.createIndex("users", "department");
    db.createIndex("users", "status");

    const startInsert = performance.now();
    for (let i = 0; i < size; i++) {
        db.insert("users", {
            name: `User_${i}`,
            age: 18 + (i % 60), // 18 to 77
            role: i % 10 === 0 ? "admin" : (i % 5 === 0 ? "manager" : "user"),
            department: ["sales", "engineering", "hr", "marketing"][i % 4],
            status: i % 3 === 0 ? "inactive" : "active",
            performance: Math.random() // Unindexed float
        });
    }
    const endInsert = performance.now();
    console.log(`Inserted ${size} records in ${(endInsert - startInsert).toFixed(2)}ms`);

    // --- 1. Simple Query (Unindexed) ---
    console.log(`\n--- 1. Simple Query (Unindexed) ---`);
    console.log(`Query: { age: 30 } -> Full table scan`);
    let start = performance.now();
    let result = db.query("users", { age: 30 });
    let end = performance.now();
    console.log(`Found ${result.length} records in ${(end - start).toFixed(2)}ms`);

    // --- 2. Simple Query (Indexed) ---
    console.log(`\n--- 2. Simple Query (Indexed) ---`);
    console.log(`Query: { role: "admin" } -> O(1) set lookup`);
    start = performance.now();
    result = db.query("users", { role: "admin" });
    end = performance.now();
    console.log(`Found ${result.length} records in ${(end - start).toFixed(2)}ms`);

    // --- 3. Complex Query (Partially Indexed) ---
    console.log(`\n--- 3. Complex Query (Partially Indexed) ---`);
    console.log(`Query: { department: "engineering", status: "active", age: { $gt: 30, $lt: 50 } }`);
    console.log(`-> Set intersection for department & status, then filter by age`);
    start = performance.now();
    result = db.query("users", { 
        department: "engineering", 
        status: "active", 
        age: { $gt: 30, $lt: 50 } 
    });
    end = performance.now();
    console.log(`Found ${result.length} records in ${(end - start).toFixed(2)}ms`);

    // --- 4. Very Complex Query (Unindexed Math) ---
    console.log(`\n--- 4. Very Complex Query (Unindexed Math + Sort) ---`);
    console.log(`Query: { role: "user", performance: { $gt: 0.9 } } + SORT by performance DESC`);
    start = performance.now();
    result = db.query("users", 
        { role: "user", performance: { $gt: 0.9 } },
        { sort: { field: "performance", order: "DESC" } }
    );
    end = performance.now();
    console.log(`Found ${result.length} records in ${(end - start).toFixed(2)}ms`);
    
    // --- 5. Empty Result Query (Fast Fail via Indices) ---
    console.log(`\n--- 5. Empty Result (Fast Fail via Indices) ---`);
    console.log(`Query: { role: "admin", department: "non_existent" }`);
    start = performance.now();
    result = db.query("users", { role: "admin", department: "non_existent" });
    end = performance.now();
    console.log(`Found ${result.length} records in ${(end - start).toFixed(2)}ms`);
}

runQueryBenchmarks();
