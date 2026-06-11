// FinVM stress / scale harness — pushes the VM and DB at large sizes, checks
// correctness + determinism, and reports time and peak heap. Use it to track
// how the VM scales as you make it "faster, larger".
//
//   npm run build && node bench/stress.js
//   LOOP_N=2000000 LIST_N=80000 DB_N=300000 node bench/stress.js
import { runJsonProgram } from '../output/FinVM.Encoding.Json/index.js';
import { FinVMDatabase } from '../src/FinVM/FFI/Database.js';
import bigInt from 'big-integer';
import { performance } from 'node:perf_hooks';
import * as fs from 'node:fs/promises';

const LOOP_N = Number(process.env.LOOP_N ?? 1_000_000);
const LIST_N = Number(process.env.LIST_N ?? 50_000);   // < default maxListLength (100000)
const DB_N = Number(process.env.DB_N ?? 200_000);

const mb = (b) => (b / 1024 / 1024).toFixed(1) + ' MB';
function heap() { return process.memoryUsage().heapUsed; }
function time(fn) { const t = performance.now(); const r = fn(); return { ms: performance.now() - t, r }; }
async function timeAsync(fn) { const t = performance.now(); const r = await fn(); return { ms: performance.now() - t, r }; }
function check(cond, msg) { if (!cond) { console.error('  ✗ ' + msg); process.exitCode = 1; } else { console.log('  ✓ ' + msg); } }

// Arithmetic loop, performanceMode on. Steps ≈ 5*n.
function loopProgram(n) {
    return JSON.stringify({
        version: '1.0', registerCount: 5, performanceMode: true,
        limits: { maxSteps: 6 * n + 100 },
        constants: [{ int: '0' }, { int: '1' }, { int: String(n) }],
        instructions: [
            ['LOAD_CONST', 1, 0], ['LOAD_CONST', 0, 0], ['LOAD_CONST', 3, 1], ['LOAD_CONST', 2, 2],
            ['LABEL', 'loop'], ['LT', 4, 0, 2], ['JUMP_IF_FALSE', 4, 'end'],
            ['ADD', 1, 1, 0], ['ADD', 0, 0, 3], ['JUMP', 'loop'],
            ['LABEL', 'end'], ['STATE_SET', 'sum', 1], ['RETURN', 1],
        ],
    });
}

// Build a list of n elements (append in a loop), then read its length.
function listProgram(n) {
    return JSON.stringify({
        version: '1.0', registerCount: 6, performanceMode: true,
        limits: { maxSteps: 8 * n + 100 },
        constants: [{ int: '0' }, { int: '1' }, { int: String(n) }],
        instructions: [
            ['LOAD_CONST', 0, 0], ['LOAD_CONST', 3, 1], ['LOAD_CONST', 2, 2],
            ['LIST_NEW', 1],
            ['LABEL', 'loop'], ['LT', 4, 0, 2], ['JUMP_IF_FALSE', 4, 'end'],
            ['LIST_APPEND', 1, 1, 0], ['ADD', 0, 0, 3], ['JUMP', 'loop'],
            ['LABEL', 'end'], ['LIST_LENGTH', 5, 1], ['STATE_SET', 'len', 5], ['RETURN', 5],
        ],
    });
}

async function main() {
    console.log(`FinVM stress harness (LOOP_N=${LOOP_N}, LIST_N=${LIST_N}, DB_N=${DB_N})`);
    const h0 = heap();

    // --- 1. Long compute loop ---
    console.log(`\n[1] arithmetic loop, ${LOOP_N.toLocaleString()} iterations (perf mode)`);
    const prog = loopProgram(LOOP_N);
    const a = time(() => runJsonProgram(prog));
    const b = time(() => runJsonProgram(prog));
    const sum = JSON.parse(a.r)?.result?.int;
    const expected = bigInt(LOOP_N).times(LOOP_N - 1).divide(2).toString();
    console.log(`    ${a.ms.toFixed(0)} ms  (${(LOOP_N / (a.ms / 1000) / 1e6).toFixed(2)} M steps-ish/s)`);
    check(sum === expected, `correct sum (${sum})`);
    check(a.r === b.r, 'deterministic across two runs (identical output)');

    // --- 2. Large list ---
    console.log(`\n[2] build a list of ${LIST_N.toLocaleString()} elements`);
    const lp = listProgram(LIST_N);
    const l = time(() => runJsonProgram(lp));
    const parsedL = JSON.parse(l.r);
    console.log(`    ${l.ms.toFixed(0)} ms  status=${parsedL.status}`);
    check(parsedL.result?.int === String(LIST_N), `list length == ${LIST_N}`);

    // --- 3. Database at scale (direct FFI) ---
    console.log(`\n[3] database: insert ${DB_N.toLocaleString()} records, index, query, hash`);
    try { await fs.unlink('.finvm.db'); } catch {}
    const db = new FinVMDatabase();
    db.createIndex('users', 'role');
    const ins = time(() => {
        for (let i = 0; i < DB_N; i++) {
            db.insert('users', { name: 'U' + i, age: 20 + (i % 50), role: i % 10 === 0 ? 'admin' : 'user' });
        }
        return true;
    });
    console.log(`    insert: ${ins.ms.toFixed(0)} ms  (${(DB_N / (ins.ms / 1000)).toLocaleString('en-US', { maximumFractionDigits: 0 })}/s)`);
    const q = time(() => db.query('users', { role: { $eq: 'admin' } }));
    console.log(`    indexed query: ${q.ms.toFixed(1)} ms  (${q.r.length} hits)`);
    check(q.r.length === Math.ceil(DB_N / 10), 'indexed query returned all admins');
    const hsh = time(() => db.hashTable('users'));
    const hsh2 = time(() => db.hashTable('users'));
    console.log(`    SHA-256 hash: ${hsh.ms.toFixed(0)} ms`);
    check(hsh.r === hsh2.r && /^[0-9a-f]{64}$/.test(hsh.r), 'table hash stable + SHA-256 shaped');
    try { await fs.unlink('.finvm.db'); } catch {}

    console.log(`\nPeak heap delta: ${mb(heap() - h0)} (heapUsed now ${mb(heap())})`);
    console.log(process.exitCode ? '\nSTRESS FAILED' : '\nStress passed.');
}

main().catch((e) => { console.error('Stress failed:', e); process.exit(1); });
