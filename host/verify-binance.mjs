// Live verification: drive a real Binance http.get through the effect driver,
// then replay the journal with ZERO network and confirm the identical value.
//
//   npm run bundle:api && node host/verify-binance.mjs
import { runLive, runReplay, createLiveHandlers } from "./index.mjs";

// Re-entrant program: run 1 requests http.get(BTCUSDT) under key "px"; run 2
// reads the body from input "px" and returns it.
const program = JSON.stringify({
  version: "1.0",
  registerCount: 6,
  constants: [
    { string: "px" },
    { string: "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT" },
    { bool: true },
  ],
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
    ["LOAD_INPUT", 0, "px"],
    ["RETURN", 0],
  ],
});

const live = await runLive(program, { handlers: createLiveHandlers() });
console.log("LIVE   :", live.value);

const replay = runReplay(program, live.journal); // no network
console.log("REPLAY :", replay.value);

if (live.value !== replay.value) {
  console.error("MISMATCH: replay did not reproduce the live value");
  process.exit(1);
}
console.log("OK: replay reproduced the live Binance value with zero network.");
console.log("journal:", JSON.stringify(live.journal));
