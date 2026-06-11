import { nativeCache } from '../src/FinVM/FFI/Cache.js';
import { performance } from 'node:perf_hooks';

function runCacheBenchmark() {
    console.log("Starting High-Speed Cache Benchmarks...\n");

    const size = 1_000_000; // 1 Million records
    console.log(`Testing with ${size.toLocaleString()} records...`);

    // --- 1. Set Benchmark ---
    let start = performance.now();
    for (let i = 0; i < size; i++) {
        nativeCache.set("global", `key_${i}`, i);
    }
    let end = performance.now();
    let setTime = end - start;
    console.log(`[Cache.set]    ${setTime.toFixed(2)}ms  -> ~${Math.floor(size / (setTime / 1000)).toLocaleString()} ops/sec`);

    // --- 2. Get Benchmark ---
    start = performance.now();
    for (let i = 0; i < size; i++) {
        nativeCache.get("global", `key_${i}`);
    }
    end = performance.now();
    let getTime = end - start;
    console.log(`[Cache.get]    ${getTime.toFixed(2)}ms  -> ~${Math.floor(size / (getTime / 1000)).toLocaleString()} ops/sec`);

    // --- 3. Random Access Benchmark ---
    // Generate 100k random keys
    const randomKeys = [];
    for(let i = 0; i < 100_000; i++) {
        randomKeys.push(`key_${Math.floor(Math.random() * size)}`);
    }

    start = performance.now();
    for (let i = 0; i < randomKeys.length; i++) {
        nativeCache.get("global", randomKeys[i]);
    }
    end = performance.now();
    let randomTime = end - start;
    console.log(`[Cache.random] ${randomTime.toFixed(2)}ms  -> ~${Math.floor(100_000 / (randomTime / 1000)).toLocaleString()} ops/sec`);


    // --- 4. Delete Benchmark (10% of items) ---
    start = performance.now();
    for (let i = 0; i < 100_000; i++) {
        nativeCache.delete("global", `key_${i}`);
    }
    end = performance.now();
    let deleteTime = end - start;
    console.log(`[Cache.delete] ${deleteTime.toFixed(2)}ms  -> ~${Math.floor(100_000 / (deleteTime / 1000)).toLocaleString()} ops/sec`);

    // --- 5. Clear Namespace Benchmark ---
    start = performance.now();
    nativeCache.clear("global");
    end = performance.now();
    console.log(`[Cache.clear]  ${(end - start).toFixed(2)}ms  (Dropped ${size - 100_000} items instantly)`);
}

runCacheBenchmark();
