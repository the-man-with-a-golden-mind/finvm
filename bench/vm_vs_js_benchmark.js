// FinVM benchmark: VM execution vs native JS, and FinVM DB vs native JS data structures.
//
//   node bench/vm_vs_js_benchmark.js        (defaults)
//   VM_ITERS=20000 DB_SIZE=20000 node bench/vm_vs_js_benchmark.js
//
// Requires a prior `npm run build` (imports the compiled VM from ./output).
import { runJsonProgram } from '../output/FinVM.Encoding.Json/index.js';
import { FinVMDatabase } from '../src/FinVM/FFI/Database.js';
import bigInt from 'big-integer';
import { performance } from 'node:perf_hooks';
import * as fs from 'node:fs/promises';

const VM_ITERS = Number(process.env.VM_ITERS ?? 20000);
const DB_SIZE = Number(process.env.DB_SIZE ?? 20000);
const REPS = Number(process.env.REPS ?? 5);

// Time `fn` REPS times and return the best (minimum) wall-clock ms.
function bestOf(fn, reps = REPS) {
    let best = Infinity;
    let last;
    for (let i = 0; i < reps; i++) {
        const t0 = performance.now();
        last = fn();
        const dt = performance.now() - t0;
        if (dt < best) best = dt;
    }
    return { ms: best, result: last };
}

function fmt(ms) { return ms.toFixed(2).padStart(10) + ' ms'; }
function rate(n, ms) { return (n / (ms / 1000)).toLocaleString('en-US', { maximumFractionDigits: 0 }) + ' ops/s'; }

function row(label, ms, n) {
    console.log(`  ${label.padEnd(34)} ${fmt(ms)}   ${rate(n, ms).padStart(18)}`);
}

// ---------------------------------------------------------------------------
// Workload A — arithmetic loop: sum of 0..N-1
// ---------------------------------------------------------------------------
// FinVM program: registers r0=i, r1=sum, r2=limit, r3=one, r4=cond.
function loopProgram(n, performanceMode = false) {
    return JSON.stringify({
        version: '1.0',
        registerCount: 5,
        performanceMode,
        limits: { maxSteps: 6 * n + 100 },
        constants: [{ int: '0' }, { int: '1' }, { int: String(n) }],
        instructions: [
            ['LOAD_CONST', 1, 0],            // sum = 0
            ['LOAD_CONST', 0, 0],            // i = 0
            ['LOAD_CONST', 3, 1],            // one = 1
            ['LOAD_CONST', 2, 2],            // limit = n
            ['LABEL', 'loop'],
            ['LT', 4, 0, 2],                 // cond = i < limit
            ['JUMP_IF_FALSE', 4, 'end'],
            ['ADD', 1, 1, 0],                // sum += i
            ['ADD', 0, 0, 3],                // i += 1
            ['JUMP', 'loop'],
            ['LABEL', 'end'],
            ['STATE_SET', 'sum', 1],
            ['RETURN', 1],
        ],
    });
}

// Same loop, but with `pad` dummy LABEL instructions before the body so the
// JUMP-back target sits at a high instruction index. With the O(1) label cache,
// per-jump cost is independent of `pad`; with the old linear scan it grew with it.
function paddedLoopProgram(n, pad) {
    const labels = [];
    for (let i = 0; i < pad; i++) labels.push(['LABEL', `pad_${i}`]);
    return JSON.stringify({
        version: '1.0',
        registerCount: 5,
        performanceMode: true,
        limits: { maxSteps: 6 * n + pad + 100 },
        constants: [{ int: '0' }, { int: '1' }, { int: String(n) }],
        instructions: [
            ...labels,
            ['LOAD_CONST', 1, 0], ['LOAD_CONST', 0, 0], ['LOAD_CONST', 3, 1], ['LOAD_CONST', 2, 2],
            ['LABEL', 'loop'],
            ['LT', 4, 0, 2], ['JUMP_IF_FALSE', 4, 'end'],
            ['ADD', 1, 1, 0], ['ADD', 0, 0, 3], ['JUMP', 'loop'],
            ['LABEL', 'end'], ['RETURN', 1],
        ],
    });
}

function benchLabelCache() {
    console.log(`\n=== Label resolution: O(1) cache vs program size (${VM_ITERS} iters, perf mode) ===`);
    const near = bestOf(() => runJsonProgram(paddedLoopProgram(VM_ITERS, 0)));
    const far = bestOf(() => runJsonProgram(paddedLoopProgram(VM_ITERS, 2000)));
    row('jump target near top (pad=0)', near.ms, VM_ITERS);
    row('jump target far down (pad=2000)', far.ms, VM_ITERS);
    console.log(`\n  ratio far/near = ${(far.ms / near.ms).toFixed(2)}x (≈1.0 means jump cost is O(1) in program size)`);
}

function benchWorkloadA() {
    console.log(`\n=== Workload A: sum of 0..${VM_ITERS - 1} (arithmetic loop) ===`);
    const expected = bigInt(VM_ITERS).times(VM_ITERS - 1).divide(2).toString();
    const progTraced = loopProgram(VM_ITERS, false);
    const progPerf = loopProgram(VM_ITERS, true);

    const vmTraced = bestOf(() => runJsonProgram(progTraced));
    const vmPerf = bestOf(() => runJsonProgram(progPerf));
    const vmSum = JSON.parse(vmPerf.result)?.result?.int;

    const jsBig = bestOf(() => {
        let sum = bigInt(0);
        for (let i = 0; i < VM_ITERS; i++) sum = sum.add(i);
        return sum.toString();
    });

    const jsNum = bestOf(() => {
        let sum = 0;
        for (let i = 0; i < VM_ITERS; i++) sum += i;
        return sum;
    });

    console.log(`  (correctness: VM=${vmSum}, expected=${expected}, match=${vmSum === expected})\n`);
    row('FinVM (tracing, default)', vmTraced.ms, VM_ITERS);
    row('FinVM (performanceMode)', vmPerf.ms, VM_ITERS);
    row('native JS + big-integer', jsBig.ms, VM_ITERS);
    row('native JS + Number', jsNum.ms, VM_ITERS);
    console.log(`\n  performanceMode is ~${(vmTraced.ms / vmPerf.ms).toFixed(2)}x faster than the tracing default`);
    console.log(`  FinVM (perf) is ~${(vmPerf.ms / jsBig.ms).toFixed(0)}x slower than JS+bigint, ~${(vmPerf.ms / jsNum.ms).toFixed(0)}x slower than JS+Number`);
    console.log('  (expected: FinVM is a safe, deterministic tree-walking interpreter, not a JIT)');
}

// ---------------------------------------------------------------------------
// Workload B — store: insert + indexed query + state hash
// ---------------------------------------------------------------------------
async function benchWorkloadB() {
    console.log(`\n=== Workload B: ${DB_SIZE} records — insert, indexed query, hash ===`);
    try { await fs.unlink('.finvm.db'); } catch {}

    const records = [];
    for (let i = 0; i < DB_SIZE; i++) {
        records.push({ name: `User_${i}`, age: 20 + (i % 40), role: i % 10 === 0 ? 'admin' : 'user', active: i % 2 === 0 });
    }

    // --- Insert ---
    console.log('\n  -- insert --');
    const fvmInsert = bestOf(() => {
        const db = new FinVMDatabase();
        db.createIndex('users', 'role');
        for (const r of records) db.insert('users', r);
        return db;
    }, 3);

    const jsInsert = bestOf(() => {
        const rows = new Map();          // id -> record
        const roleIdx = new Map();       // role -> Set(id)
        let seq = 0;
        for (const r of records) {
            const id = 'rec' + seq++;
            rows.set(id, r);
            if (!roleIdx.has(r.role)) roleIdx.set(r.role, new Set());
            roleIdx.get(r.role).add(id);
        }
        return { rows, roleIdx };
    }, 3);

    row('FinVM DB (indexed)', fvmInsert.ms, DB_SIZE);
    row('native JS Map + index', jsInsert.ms, DB_SIZE);
    console.log(`  FinVM DB is ~${(fvmInsert.ms / jsInsert.ms).toFixed(1)}x slower on insert`);

    // --- Indexed query: role == admin ---
    console.log('\n  -- indexed query (role = admin) --');
    const fdb = fvmInsert.result;
    const { rows, roleIdx } = jsInsert.result;

    const fvmQuery = bestOf(() => fdb.query('users', { role: { $eq: 'admin' } }));
    const jsQuery = bestOf(() => {
        const ids = roleIdx.get('admin') ?? new Set();
        const out = [];
        for (const id of ids) out.push(rows.get(id));
        return out;
    });
    const nQ = fvmQuery.result.length;
    row(`FinVM DB query (${nQ} hits)`, fvmQuery.ms, nQ || 1);
    row('native JS index lookup', jsQuery.ms, nQ || 1);
    console.log(`  FinVM DB query is ~${(fvmQuery.ms / Math.max(jsQuery.ms, 0.0001)).toFixed(1)}x slower`);

    // --- State hash ---
    console.log('\n  -- table / state hash --');
    const fvmHash = bestOf(() => fdb.hashTable('users'));
    const jsHash = bestOf(() => {
        // naive comparable: JSON of sorted rows (NOT cryptographic, for scale reference only)
        return JSON.stringify(Array.from(rows.values()));
    });
    row('FinVM SHA-256 table hash', fvmHash.ms, DB_SIZE);
    row('native JSON.stringify (ref)', jsHash.ms, DB_SIZE);

    try { await fs.unlink('.finvm.db'); } catch {}
}

async function main() {
    console.log('FinVM Benchmark — VM vs native JS, DB vs native data structures');
    console.log(`(VM_ITERS=${VM_ITERS}, DB_SIZE=${DB_SIZE}, best of ${REPS} reps)`);
    benchWorkloadA();
    benchLabelCache();
    await benchWorkloadB();
    console.log('\nDone.');
}

main().catch((e) => { console.error('Benchmark failed:', e); process.exit(1); });
