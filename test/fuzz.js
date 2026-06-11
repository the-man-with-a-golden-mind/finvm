// FinVM fuzzer — generates random (valid-by-construction) programs and checks
// VM invariants: (1) runJsonProgram NEVER throws an uncaught host exception —
// every input yields a parseable JSON status; (2) execution is deterministic —
// running the same program twice yields identical output. Failures print the
// seed and the offending program so they reproduce exactly.
//
//   npm run build && node test/fuzz.js
//   FUZZ_ITERS=50000 FUZZ_SEED=123 node test/fuzz.js
import { runJsonProgram } from '../output/FinVM.Encoding.Json/index.js';

const ITERS = Number(process.env.FUZZ_ITERS ?? 20000);
const SEED = Number(process.env.FUZZ_SEED ?? 0xC0FFEE);

// Deterministic PRNG (mulberry32) so any failure is reproducible from its seed.
function mulberry32(a) {
    return function () {
        a |= 0; a = (a + 0x6D2B79F5) | 0;
        let t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

const LABELS = ['L0', 'L1', 'end'];

function makeGen(seed) {
    const rnd = mulberry32(seed);
    const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));
    const pick = (arr) => arr[int(0, arr.length - 1)];
    return { rnd, int, pick };
}

// Build one random program with R registers and a handful of declared labels.
function genProgram(g) {
    const R = g.int(3, 8);
    const numConst = g.int(1, 4);
    const constants = [];
    for (let i = 0; i < numConst; i++) {
        constants.push(g.rnd() < 0.8 ? { int: String(g.int(-50, 50)) } : { string: 'c' + i });
    }
    const reg = () => g.int(0, R - 1);
    const cst = () => g.int(0, numConst - 1);
    const lbl = () => g.pick(LABELS);

    const ops = [
        () => ['NOOP'],
        () => ['LOAD_CONST', reg(), cst()],
        () => ['MOVE', reg(), reg()],
        () => ['CLEAR', reg()],
        () => ['ADD', reg(), reg(), reg()],
        () => ['SUB', reg(), reg(), reg()],
        () => ['MUL', reg(), reg(), reg()],
        () => ['EQ', reg(), reg(), reg()],
        () => ['LT', reg(), reg(), reg()],
        () => ['GT', reg(), reg(), reg()],
        () => ['NEG', reg(), reg()],
        () => ['ABS', reg(), reg()],
        () => ['JUMP', lbl()],
        () => ['JUMP_IF', reg(), lbl()],
        () => ['JUMP_IF_FALSE', reg(), lbl()],
        () => ['STATE_SET', 'k' + g.int(0, 3), reg()],
        () => ['STATE_GET', reg(), 'k' + g.int(0, 3)],
        () => ['RECORD_NEW', reg()],
        () => ['LIST_NEW', reg()],
        () => ['LIST_APPEND', reg(), reg(), reg()],
        () => ['RETURN', reg()],
        () => ['HALT', reg()],
    ];

    const body = [['LABEL', 'L0']];
    const n = g.int(1, 30);
    for (let i = 0; i < n; i++) body.push(g.pick(ops)());
    // Declare the remaining labels so every JUMP target resolves.
    body.push(['LABEL', 'L1'], ['LABEL', 'end'], ['RETURN', 0]);

    return JSON.stringify({
        version: '1.0',
        registerCount: R,
        // Step cap guarantees termination even if the program loops forever.
        limits: { maxSteps: 2000 },
        performanceMode: g.rnd() < 0.5,
        constants,
        instructions: body,
    });
}

function run() {
    console.log(`FinVM fuzzer: ${ITERS} programs, seed=${SEED}`);
    let crashes = 0, nondeterministic = 0, ok = 0;
    const failures = [];

    for (let i = 0; i < ITERS; i++) {
        const g = makeGen(SEED + i);
        const prog = genProgram(g);
        let out1, out2;
        try {
            out1 = runJsonProgram(prog);
            out2 = runJsonProgram(prog);
        } catch (e) {
            crashes++;
            if (failures.length < 5) failures.push({ kind: 'throw', seed: SEED + i, err: String(e), prog });
            continue;
        }
        // Invariant 1: output must be parseable JSON with a status field.
        let parsed;
        try { parsed = JSON.parse(out1); } catch {
            crashes++;
            if (failures.length < 5) failures.push({ kind: 'unparseable', seed: SEED + i, out: out1, prog });
            continue;
        }
        if (typeof parsed.status !== 'string') {
            crashes++;
            if (failures.length < 5) failures.push({ kind: 'no-status', seed: SEED + i, out: out1, prog });
            continue;
        }
        // Invariant 2: determinism.
        if (out1 !== out2) {
            nondeterministic++;
            if (failures.length < 5) failures.push({ kind: 'nondeterministic', seed: SEED + i, a: out1, b: out2, prog });
            continue;
        }
        ok++;
    }

    console.log(`  ok=${ok}  crashes=${crashes}  nondeterministic=${nondeterministic}`);
    if (failures.length) {
        console.log('\n  First failures (reproduce with FUZZ_SEED=<seed> FUZZ_ITERS=1):');
        for (const f of failures) console.log('   ', JSON.stringify(f).slice(0, 600));
    }
    if (crashes || nondeterministic) {
        console.error('\nFUZZ FAILED');
        process.exit(1);
    }
    console.log('\nFuzz passed: no crashes, fully deterministic.');
}

run();
