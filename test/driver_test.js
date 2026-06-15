// Tests for the host effect driver (host/driver.mjs).
// Requires the API bundle: `npm run bundle:api` (the test:driver script does this).
import assert from "node:assert";
import { performance } from "node:perf_hooks";
import { runLive, runReplay } from "../host/index.mjs";
import { runEffectStart, runEffectResume } from "../dist/finvm-api.js";

// Async-effect program: one EFFECT_AWAIT and return delivered value.
const singleProgram = JSON.stringify({
  version: "1.0",
  registerCount: 6,
  constants: [{ string: "k1" }, { string: "http://x" }],
  instructions: [
    ["RECORD_NEW", 0],
    ["LOAD_CONST", 1, 0], ["RECORD_SET", 0, 0, "key", 1],
    ["LOAD_CONST", 2, 1], ["RECORD_SET", 0, 0, "url", 2],
    ["EFFECT_NEW", 3, "http.get", 0],
    ["EFFECT_AWAIT", 3],
    ["PROC_RECEIVE", 4],
    ["VARIANT_PAYLOAD", 5, 4],
    ["RECORD_GET", 4, 5, "value"],
    ["RETURN", 4],
  ],
});

// Batch async program:
// - main spawns w0/w1/w2
// - each worker EFFECT_AWAITs one http.get
// - after resume/deliveries, workers return values and main joins them
const batchProgram = JSON.stringify({
  version: "1.0",
  functions: {
    main: {
      registerCount: 10,
      instructions: [
        ["PROC_SPAWN", 0, "w0", []],
        ["PROC_SPAWN", 1, "w1", []],
        ["PROC_SPAWN", 2, "w2", []],
        ["PROC_JOIN_RESULT", 3, 0],
        ["PROC_JOIN_RESULT", 4, 1],
        ["PROC_JOIN_RESULT", 5, 2],
        ["RECORD_NEW", 6],
        ["RECORD_SET", 6, 6, "a", 3],
        ["RECORD_SET", 6, 6, "b", 4],
        ["RECORD_SET", 6, 6, "c", 5],
        ["RETURN", 6],
      ],
    },
    w0: {
      registerCount: 6,
      instructions: [
        ["RECORD_NEW", 0],
        ["LOAD_CONST", 1, 0], ["RECORD_SET", 0, 0, "key", 1],
        ["LOAD_CONST", 2, 3], ["RECORD_SET", 0, 0, "url", 2],
        ["EFFECT_NEW", 3, "http.get", 0],
        ["EFFECT_AWAIT", 3],
        ["PROC_RECEIVE", 4],
        ["VARIANT_PAYLOAD", 5, 4],
        ["RECORD_GET", 4, 5, "value"],
        ["RETURN", 4],
      ],
    },
    w1: {
      registerCount: 6,
      instructions: [
        ["RECORD_NEW", 0],
        ["LOAD_CONST", 1, 1], ["RECORD_SET", 0, 0, "key", 1],
        ["LOAD_CONST", 2, 4], ["RECORD_SET", 0, 0, "url", 2],
        ["EFFECT_NEW", 3, "http.get", 0],
        ["EFFECT_AWAIT", 3],
        ["PROC_RECEIVE", 4],
        ["VARIANT_PAYLOAD", 5, 4],
        ["RECORD_GET", 4, 5, "value"],
        ["RETURN", 4],
      ],
    },
    w2: {
      registerCount: 6,
      instructions: [
        ["RECORD_NEW", 0],
        ["LOAD_CONST", 1, 2], ["RECORD_SET", 0, 0, "key", 1],
        ["LOAD_CONST", 2, 5], ["RECORD_SET", 0, 0, "url", 2],
        ["EFFECT_NEW", 3, "http.get", 0],
        ["EFFECT_AWAIT", 3],
        ["PROC_RECEIVE", 4],
        ["VARIANT_PAYLOAD", 5, 4],
        ["RECORD_GET", 4, 5, "value"],
        ["RETURN", 4],
      ],
    },
  },
  entrypoint: "main",
  constants: [
    { string: "k0" }, { string: "k1" }, { string: "k2" },
    { string: "u0" }, { string: "u1" }, { string: "u2" },
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
  assert.strictEqual(live.journal[0].kind, "await_reply");
  assert.strictEqual(live.journal[0].type_, "http.get");
  assert.strictEqual(typeof live.journal[0].pid, "string");
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

  assert.deepStrictEqual(
    Object.keys(batch.value).sort(),
    ["a", "b", "c"],
    "main returns a record with expected keys after resume"
  );
  assert.deepStrictEqual(batch.journal.map((e) => e.key), ["k0", "k1", "k2"], "journal in REQUEST order (deterministic)");
  assert.ok(batch.journal.every((e) => typeof e.pid === "string" && e.pid.length > 0), "journal includes pids");
  assert.deepStrictEqual(completion, ["k2", "k1", "k0"], "handlers completed out of order (proves concurrency)");
  // Keep a loose runtime guard to avoid CI/local jitter flakes:
  // sequential is ~240ms (plus overhead), concurrent should still stay well below that.
  assert.ok(elapsed < 260, `batch ran concurrently (elapsed ${elapsed.toFixed(0)}ms < 260ms)`);

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

  // --- 6. Cross-VM actor messaging via NODE_SEND transport intent ---
  console.log("6. cross-VM actor message delivery");
  const senderProgram = JSON.stringify({
    version: "1.0",
    registerCount: 6,
    constants: [{ string: "vmB" }, { string: "main" }, { string: "PING" }],
    instructions: [
      ["LOAD_CONST", 1, 0],
      ["LOAD_CONST", 2, 1],
      ["REMOTE_PID_NEW", 0, 1, 2],
      ["LOAD_CONST", 3, 2],
      ["NODE_SEND", 0, 3],
      ["HALT", 3],
    ],
  });
  const receiverProgram = JSON.stringify({
    version: "1.0",
    registerCount: 1,
    constants: [],
    instructions: [
      ["PROC_RECEIVE", 0],
      ["RETURN", 0],
    ],
  });

  // VM-B starts and parks waiting for mailbox input.
  const bStart = JSON.parse(runEffectStart(receiverProgram)(""));
  assert.strictEqual(bStart.status, "deadlock", "receiver parks on PROC_RECEIVE before network delivery");

  // Simulated network transport queues deliveries keyed by node.
  const network = { vmB: [] };
  const senderOut = await runLive(senderProgram, {
    handlers: {
      RemoteSendIntent: async (p) => {
        network[p.node] ??= [];
        network[p.node].push({ pid: p.pid, message: p.message });
        return true;
      },
    },
  });
  assert.strictEqual(senderOut.value, "PING", "sender VM completed locally");
  assert.strictEqual(senderOut.journal.length, 1, "sender journals transport intent");
  assert.strictEqual(senderOut.journal[0].kind, "transport");
  assert.strictEqual(senderOut.journal[0].type_, "RemoteSendIntent");

  const deliveriesJson = JSON.stringify(network.vmB);
  const bResume = JSON.parse(runEffectResume(receiverProgram)(JSON.stringify(bStart.snapshot))(deliveriesJson));
  assert.strictEqual(bResume.status, "completed", "receiver resumes and consumes delivered message");
  assert.deepStrictEqual(bResume.result, { string: "PING" }, "receiver gets remote actor message");

  // --- 7. Remote monitor disconnect -> DOWN mailbox message ---
  console.log("7. remote monitor disconnect delivery");
  const monitorProgram = JSON.stringify({
    version: "1.0",
    registerCount: 7,
    constants: [{ string: "vmB" }, { string: "remote-1" }],
    instructions: [
      ["LOAD_CONST", 1, 0],
      ["LOAD_CONST", 2, 1],
      ["REMOTE_PID_NEW", 0, 1, 2],
      ["NODE_MONITOR", 3, 0],
      ["PROC_RECEIVE", 4],
      ["VARIANT_PAYLOAD", 5, 4],
      ["RECORD_GET", 6, 5, "reason"],
      ["RETURN", 6],
    ],
  });
  const mStart = JSON.parse(runEffectStart(monitorProgram)(""));
  assert.strictEqual(mStart.status, "suspended", "monitoring process suspends with pending monitor intent");
  assert.strictEqual(mStart.pending.length, 1, "single monitor intent pending");
  assert.strictEqual(mStart.pending[0].type_, "RemoteMonitorIntent");
  const mDeliveries = JSON.stringify([{ disconnect: { node: "vmB", reason: "net-split" } }]);
  const mResume = JSON.parse(runEffectResume(monitorProgram)(JSON.stringify(mStart.snapshot))(mDeliveries));
  assert.strictEqual(mResume.status, "completed", "disconnect wakes monitor with DOWN");
  assert.deepStrictEqual(mResume.result, { string: "net-split" }, "disconnect reason propagates via DOWN payload");

  // --- 8. Node lifecycle delivery drives NODE_STATUS/NODE_LAST_* deterministically ---
  console.log("8. node lifecycle status delivery");
  const nodeStatusProgram = JSON.stringify({
    version: "1.0",
    registerCount: 8,
    constants: [{ string: "vmB" }],
    instructions: [
      ["LOAD_CONST", 1, 0],
      ["PROC_RECEIVE", 0],
      ["NODE_STATUS", 2, 1],
      ["NODE_LAST_SEEN_TICK", 3, 1],
      ["NODE_LAST_STATE_HASH", 4, 1],
      ["RECORD_NEW", 5],
      ["RECORD_SET", 5, 5, "status", 2],
      ["RECORD_SET", 5, 5, "tick", 3],
      ["RECORD_SET", 5, 5, "hash", 4],
      ["RETURN", 5],
    ],
  });
  const nsStart = JSON.parse(runEffectStart(nodeStatusProgram)(""));
  assert.strictEqual(nsStart.status, "deadlock", "status program parks on mailbox receive");
  const nsDeliveries = JSON.stringify([
    { nodeStatus: { node: "vmB", status: "suspect", reason: "timeout", lastSeenTick: 7, lastStateHash: "h_vmB_1" } },
    { pid: "main", message: { string: "wake" } },
  ]);
  const nsResume = JSON.parse(runEffectResume(nodeStatusProgram)(JSON.stringify(nsStart.snapshot))(nsDeliveries));
  assert.strictEqual(nsResume.status, "completed", "node status delivery persists metadata and resume completes");
  assert.deepStrictEqual(
    nsResume.result,
    { record: {
      status: { string: "suspect" },
      tick: { option: { int: "7" } },
      hash: { option: { string: "h_vmB_1" } },
    } },
    "NODE_STATUS/NODE_LAST_* read host-delivered lifecycle metadata"
  );

  // --- 9. NODE_SPAWN completion through transport delivery contract ---
  console.log("9. remote spawn ack/fail completion delivery");
  const spawnProgram = JSON.stringify({
    version: "1.0",
    functions: {
      main: {
        registerCount: 6,
        instructions: [
          ["LOAD_CONST", 1, 0],
          ["NODE_SPAWN", 0, 1, "worker", []],
          ["PROC_RECEIVE", 2],
          ["VARIANT_TAG", 3, 2],
          ["RETURN", 3],
        ],
      },
      worker: {
        registerCount: 1,
        instructions: [
          ["HALT", 0],
        ],
      },
    },
    entrypoint: "main",
    constants: [{ string: "vmB" }],
  });
  const spawnOk = await runLive(spawnProgram, {
    handlers: {
      RemoteSpawnIntent: async (p) => ({
        deliveries: [
          { pid: p.requesterPid, message: { tag: "RemoteSpawnAck", payload: { requestId: p.requestId, pid: p.pid } } },
        ],
      }),
    },
  });
  assert.strictEqual(spawnOk.value, "RemoteSpawnAck", "NODE_SPAWN success is delivered as deterministic mailbox ack");
  assert.strictEqual(spawnOk.journal[0].type_, "RemoteSpawnIntent");
  const spawnFail = await runLive(spawnProgram, {
    handlers: {
      RemoteSpawnIntent: async (p) => ({
        deliveries: [
          { nodeStatus: { node: p.node, status: "offline", reason: "unreachable" } },
          { pid: p.requesterPid, message: { tag: "RemoteSpawnFailed", payload: { reason: "unreachable", requestId: p.requestId } } },
        ],
      }),
    },
  });
  assert.strictEqual(spawnFail.value, "RemoteSpawnFailed", "NODE_SPAWN failure is deterministic and replayable");
  const spawnFailReplay = runReplay(spawnProgram, spawnFail.journal);
  assert.strictEqual(spawnFailReplay.value, spawnFail.value, "spawn-fail transport flow replays with identical final value");

  // --- 10. Remote link disconnect obeys trap-exit semantics ---
  console.log("10. remote link disconnect semantics");
  const linkedProgram = JSON.stringify({
    version: "1.0",
    registerCount: 7,
    constants: [{ string: "vmB" }, { string: "remote-1" }],
    instructions: [
      ["LOAD_CONST", 1, 0],
      ["LOAD_CONST", 2, 1],
      ["REMOTE_PID_NEW", 0, 1, 2],
      ["PROC_TRAP_EXIT", true],
      ["NODE_LINK", 0],
      ["PROC_RECEIVE", 3],
      ["VARIANT_TAG", 4, 3],
      ["RETURN", 4],
    ],
  });
  const linkedStart = JSON.parse(runEffectStart(linkedProgram)(""));
  assert.strictEqual(linkedStart.status, "suspended", "linked process should suspend with transport pending");
  assert.strictEqual(linkedStart.pending[0].type_, "RemoteLinkIntent");
  const linkedResume = JSON.parse(
    runEffectResume(linkedProgram)(JSON.stringify(linkedStart.snapshot))(JSON.stringify([{ disconnect: { node: "vmB", reason: "noconnection" } }]))
  );
  assert.strictEqual(linkedResume.status, "completed");
  assert.deepStrictEqual(linkedResume.result, { string: "EXIT" }, "trap-exit process receives EXIT message on remote disconnect");
  const linkedLive = await runLive(linkedProgram, {
    handlers: {
      RemoteLinkIntent: async (p) => ({ deliveries: [{ disconnect: { node: p.node, reason: "noconnection" } }] }),
    },
  });
  const linkedReplay = runReplay(linkedProgram, linkedLive.journal);
  assert.strictEqual(linkedLive.value, "EXIT", "live transport disconnect preserves trap-exit semantics");
  assert.strictEqual(linkedReplay.value, linkedLive.value, "transport disconnect replay preserves trap-exit semantics");

  const linkedNoTrapProgram = JSON.stringify({
    version: "1.0",
    registerCount: 6,
    constants: [{ string: "vmB" }, { string: "remote-1" }],
    instructions: [
      ["LOAD_CONST", 1, 0],
      ["LOAD_CONST", 2, 1],
      ["REMOTE_PID_NEW", 0, 1, 2],
      ["NODE_LINK", 0],
      ["PROC_RECEIVE", 3],
      ["RETURN", 3],
    ],
  });
  const linkedNoTrapStart = JSON.parse(runEffectStart(linkedNoTrapProgram)(""));
  const linkedNoTrapResume = JSON.parse(
    runEffectResume(linkedNoTrapProgram)(JSON.stringify(linkedNoTrapStart.snapshot))(JSON.stringify([{ disconnect: { node: "vmB", reason: "noconnection" } }]))
  );
  assert.strictEqual(linkedNoTrapResume.status, "completed", "non-trap linked process exits on disconnect");
  assert.strictEqual(linkedNoTrapResume.result, null, "exited process has no return value");
  const linkedNoTrapLive = await runLive(linkedNoTrapProgram, {
    handlers: {
      RemoteLinkIntent: async (p) => ({ deliveries: [{ disconnect: { node: p.node, reason: "noconnection" } }] }),
    },
  });
  const linkedNoTrapReplay = runReplay(linkedNoTrapProgram, linkedNoTrapLive.journal);
  assert.strictEqual(linkedNoTrapLive.value, null, "live disconnect exits non-trap linked process");
  assert.strictEqual(linkedNoTrapReplay.value, linkedNoTrapLive.value, "transport disconnect replay preserves non-trap exit semantics");

  // --- 11. NODE_UNLINK prevents disconnect EXIT delivery ---
  console.log("11. remote unlink suppresses disconnect side-effect");
  const unlinkProgram = JSON.stringify({
    version: "1.0",
    registerCount: 9,
    constants: [{ string: "vmB" }, { string: "remote-1" }, { string: "alive" }],
    instructions: [
      ["LOAD_CONST", 1, 0],
      ["LOAD_CONST", 2, 1],
      ["REMOTE_PID_NEW", 0, 1, 2],
      ["PROC_TRAP_EXIT", true],
      ["NODE_LINK", 0],
      ["NODE_UNLINK", 0],
      ["LOAD_CONST", 4, 2],
      ["RETURN", 4],
    ],
  });
  const unlinkStart = JSON.parse(runEffectStart(unlinkProgram)(""));
  assert.strictEqual(unlinkStart.status, "suspended");
  assert.deepStrictEqual(unlinkStart.pending.map((p) => p.type_), ["RemoteLinkIntent", "RemoteUnlinkIntent"]);
  const unlinkResume = JSON.parse(
    runEffectResume(unlinkProgram)(JSON.stringify(unlinkStart.snapshot))(JSON.stringify([{ disconnect: { node: "vmB", reason: "net" } }]))
  );
  assert.strictEqual(unlinkResume.status, "completed");
  assert.deepStrictEqual(unlinkResume.result, { string: "alive" }, "disconnect after unlink should not inject EXIT");

  console.log("All effect driver tests passed. 🚀");
}

main().catch((e) => { console.error("Driver test failed:", e); process.exit(1); });
