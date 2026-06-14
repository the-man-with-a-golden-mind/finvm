// Tests for the host effect driver (host/driver.mjs).
// Requires the API bundle: `npm run bundle:api` (the test:driver script does this).
import assert from "node:assert";
import { performance } from "node:perf_hooks";
import { runLive, runReplay } from "../host/index.mjs";

// Re-entrant program: run 1 requests one http.get (key "k1") and marks state;
// run 2 (state.requested set) reads the delivered result from input "k1".
const singleProgram = JSON.stringify({
  version: "1.0",
  registerCount: 6,
  constants: [{ string: "k1" }, { string: "http://x" }, { bool: true }],
  instructions: [
    ["STATE_EXISTS", 0, "requested"],
    ["JUMP_IF", 0, "read"],
    ["RECORD_NEW", 1],
    ["LOAD_CONST", 2, 0], ["RECORD_SET", 1, 1, "key", 2],
    ["LOAD_CONST", 3, 1], ["RECORD_SET", 1, 1, "url", 3],
    ["EFFECT_NEW", 4, "http.get", 1],
    ["EFFECT_REQUEST", 4],
    ["LOAD_CONST", 5, 2], ["STATE_SET", "requested", 5],
    ["RETURN", 1],
    ["LABEL", "read"],
    ["LOAD_INPUT", 0, "k1"],
    ["RETURN", 0],
  ],
});

// Batch program: run 1 requests three http.get at once (k0,k1,k2); run 2 reads
// them into a record {a,b,c} in request order.
const batchProgram = JSON.stringify({
  version: "1.0",
  registerCount: 8,
  constants: [
    { string: "k0" }, { string: "k1" }, { string: "k2" },
    { string: "u0" }, { string: "u1" }, { string: "u2" }, { bool: true },
  ],
  instructions: [
    ["STATE_EXISTS", 0, "requested"],
    ["JUMP_IF", 0, "read"],
    ["RECORD_NEW", 1], ["LOAD_CONST", 2, 0], ["RECORD_SET", 1, 1, "key", 2], ["LOAD_CONST", 3, 3], ["RECORD_SET", 1, 1, "url", 3], ["EFFECT_NEW", 4, "http.get", 1], ["EFFECT_REQUEST", 4],
    ["RECORD_NEW", 1], ["LOAD_CONST", 2, 1], ["RECORD_SET", 1, 1, "key", 2], ["LOAD_CONST", 3, 4], ["RECORD_SET", 1, 1, "url", 3], ["EFFECT_NEW", 4, "http.get", 1], ["EFFECT_REQUEST", 4],
    ["RECORD_NEW", 1], ["LOAD_CONST", 2, 2], ["RECORD_SET", 1, 1, "key", 2], ["LOAD_CONST", 3, 5], ["RECORD_SET", 1, 1, "url", 3], ["EFFECT_NEW", 4, "http.get", 1], ["EFFECT_REQUEST", 4],
    ["LOAD_CONST", 5, 6], ["STATE_SET", "requested", 5],
    ["RETURN", 1],
    ["LABEL", "read"],
    ["RECORD_NEW", 6],
    ["LOAD_INPUT", 7, "k0"], ["RECORD_SET", 6, 6, "a", 7],
    ["LOAD_INPUT", 7, "k1"], ["RECORD_SET", 6, 6, "b", 7],
    ["LOAD_INPUT", 7, "k2"], ["RECORD_SET", 6, 6, "c", 7],
    ["RETURN", 6],
  ],
});

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  console.log("Starting effect driver tests...");

  // --- 1. Live mock round-trip ---
  console.log("1. live mock round-trip");
  let httpCalls = 0;
  const mock = { "http.get": async (p) => { httpCalls++; return "PRICE=42 for " + p.url; } };
  const live = await runLive(singleProgram, { handlers: mock });
  assert.strictEqual(live.value, "PRICE=42 for http://x", "value delivered back into the VM");
  assert.strictEqual(live.journal.length, 1, "one effect journaled");
  assert.strictEqual(live.journal[0].type_, "http.get");
  assert.strictEqual(live.journal[0].key, "k1");
  assert.strictEqual(httpCalls, 1, "handler called exactly once");

  // --- 2. Replay: zero I/O, identical value ---
  console.log("2. replay (zero I/O) reproduces value");
  const replay = runReplay(singleProgram, live.journal);
  assert.strictEqual(replay.value, live.value, "replay reproduces the live value with no handlers/network");
  assert.ok(!(replay instanceof Promise), "replay is synchronous");

  // --- 3. Batch: concurrent, deterministic request order ---
  console.log("3. batched effects: concurrent + in request order");
  const completion = [];
  const batchMock = {
    "http.get": async (p) => {
      const idx = Number(p.url.slice(1));      // u0->0, u1->1, u2->2
      await delay((3 - idx) * 40);             // u2 finishes first, u0 last
      completion.push(p.key);
      return "val:" + p.key;
    },
  };
  const t0 = performance.now();
  const batch = await runLive(batchProgram, { handlers: batchMock });
  const elapsed = performance.now() - t0;

  assert.deepStrictEqual(batch.value, { a: "val:k0", b: "val:k1", c: "val:k2" }, "results delivered by key");
  assert.deepStrictEqual(batch.journal.map((e) => e.key), ["k0", "k1", "k2"], "journal in REQUEST order (deterministic)");
  assert.deepStrictEqual(completion, ["k2", "k1", "k0"], "handlers completed out of order (proves concurrency)");
  // sequential would be ~120+80+40=240ms; concurrent ~120ms
  assert.ok(elapsed < 200, `batch ran concurrently (elapsed ${elapsed.toFixed(0)}ms < 200ms)`);

  // --- 4. Replay the batch: zero I/O, same values, same order ---
  console.log("4. replay batch (zero I/O)");
  const batchReplay = runReplay(batchProgram, batch.journal);
  assert.deepStrictEqual(batchReplay.value, batch.value, "batch replay reproduces values");

  // --- 5. Unknown effect type -> clean error, not a crash ---
  console.log("5. unknown effect type -> clean error");
  await assert.rejects(
    () => runLive(singleProgram, { handlers: {} }),
    /No handler for effect type: http\.get/,
    "unknown handler rejects cleanly",
  );

  console.log("All effect driver tests passed. 🚀");
}

main().catch((e) => { console.error("Driver test failed:", e); process.exit(1); });
