// Public entry point for the FinVM host effect driver.
//
//   import { runLive, runReplay, createRegistry, createLiveHandlers } from "./host/index.mjs";
//   const { value, events, journal } = await runLive(programSource, { handlers });
//   const replay = runReplay(programSource, journal);   // sync, zero I/O
//
// Browser vs Node supply different handlers (createLiveHandlers takes fetchImpl,
// log, and a storage backend). See docs/EFFECTS.md.

export { runLive, runReplay, valueToJs, jsToValue } from "./driver.mjs";
export { createLiveHandlers, createMockHandlers, memoryStorage } from "./handlers.mjs";

// Small handler-registration helper the host can build up incrementally.
export function createRegistry(initial = {}) {
  const handlers = { ...initial };
  return {
    register(type_, fn) { handlers[type_] = fn; return this; },
    handlers,
  };
}
