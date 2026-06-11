# FinVM — Improvement & Fix Plan

_Audit date: 2026-06-11. Status at audit: `spago build` succeeds, `npm test` passes 57/57 PureScript specs + JS DB tests. The issues below are correctness/security/robustness/hygiene gaps, not test failures._

> **Resolution (2026-06-11): all 13 items below are implemented and tested.** Suite is now **84/84** PureScript specs + JS DB tests. Two items uncovered *real bugs* while being fixed:
> - **#6** was not just a docs item: `Fixed.roundedQuotient` mixed Data.BigInt's Euclidean `/` with the truncating `rem`, giving wrong rounding for negative operands. Fixed to use `quot`/`rem` consistently; covered by rounding-mode tests incl. negatives.
> - **#12** revealed the JSON codec was **not round-trip-safe**: `valueToJson` emitted `fixed`/`rational` tags that `decodeValue` did not handle, so they decoded back as `VRecord`. Added decode cases + round-trip tests.
>
> A VM-vs-native-JS-vs-DB benchmark was also added (`npm run bench`, `bench/vm_vs_js_benchmark.js`).

This plan is prioritized. Each item lists **what**, **why**, **where**, and a **concrete fix**. Severities: 🔴 critical · 🟠 high · 🟡 medium · 🔵 low/polish.

---

## P0 — Project hygiene & release blockers

### 1. 🟠 Repository is not under version control
- **What:** `git status` reports "not a git repository", yet the project ships `.github/workflows/ci.yml` and a `.gitignore`. CI will therefore **never run**.
- **Why it matters:** No history, no CI, no PR review, no rollback. The CI config is dead weight today.
- **Fix:**
  1. `git init` at the project root.
  2. Verify `.gitignore` excludes build artifacts (it covers `/output/`, `/.spago`, `/dist/`, `/.cache/`, `/.finvm.db`).
  3. Also add `/.spec-results` and `/.psc-ide-port` to `.gitignore` — they are local run artifacts currently untracked-but-present.
  4. Initial commit, push, confirm the CI workflow runs green on GitHub.

### 2. 🟠 No README
- **What:** There is no `README.md`. The project has rich `docs/` and an `LLM.txt`, but no human entry point.
- **Why it matters:** First thing any contributor/user looks for. The npm package (`files` includes `docs`, `LLM.txt` but no README) ships without one.
- **Fix:** Add `README.md` covering: one-paragraph "what is FinVM", install (`npm i`), build (`npm run build`), test (`npm test`), CLI usage (`finvm run <file.json>`, `finvm bench`), a minimal program example, and links into `docs/` (SPEC, INSTRUCTION_SET, DATABASE, DEBUGGING, COMPILER_TARGET) and `LLM.txt`.

### 3. 🟡 Package metadata is incomplete
- **What:** `package.json` has empty `author`, empty `keywords`, `license: "ISC"`. `repository`/`bugs`/`homepage` absent.
- **Fix:** Fill `author`, `keywords` (`vm`, `bytecode`, `deterministic`, `purescript`, `bigint`), confirm intended `license`, add `repository` once the git remote exists.

---

## P1 — CLI correctness & robustness

### 4. 🟠 CLI always exits 0, even on failure
- **What:** Confirmed by running the built binary:
  - `finvm run /nonexistent.json` → raw Node `ENOENT` stack trace dumped to stderr, **exit code 0**.
  - A program that fails at runtime prints `{"status":"failed", "error": "..."}` but **exit code 0**.
- **Why it matters:** Scripts and CI cannot detect failures; a broken program looks "successful" to any caller.
- **Where:** [src/Main.purs](../src/Main.purs), [src/FinVM/Encoding/Json.purs](../src/FinVM/Encoding/Json.purs) (`runJsonProgram`).
- **Fix:**
  1. Wrap `readTextFile` so a missing/unreadable file produces a clean `{"status":"error","error":"..."}` message instead of an uncaught exception + stack trace.
  2. Set a non-zero exit code (`Node.Process.setExitCode`/`exit 1`) when the program result `status` is `failed`/`error` or when args are invalid.
  3. Treat the "no path / no subcommand" usage output as exit 0 (help is not an error), but unknown subcommands as exit 1.

---

## P2 — Numeric & VM correctness

### 5. 🟡 `modPow` returns `0` as a silent error sentinel for negative exponents
- **What:** [src/FinVM/Numeric/BigInt.purs:30-33](../src/FinVM/Numeric/BigInt.purs#L30-L33) — when `exp < 0` and no modular inverse exists, it returns `fromInt 0` ("`-- or error`"). `0` is also a legitimate result for other inputs, so the error is indistinguishable from a real answer.
- **Why it matters:** In a VM that markets cryptographic builtins (`bigint.modPow@1`, `bigint.modInv@1`), silently returning a wrong-but-plausible value is a correctness hazard.
- **Fix:** Make `modPow` total-but-honest: either return `Maybe BigInt`/`Either ErrorCode BigInt` and surface a `DivisionByZero`/`NoModularInverse` error through the builtin layer ([src/FinVM/Builtin.purs](../src/FinVM/Builtin.purs)), or guarantee callers validate invertibility first. Add a test for the no-inverse case asserting an error, not `0`.

### 6. 🔵 Document `Fixed.div` scale semantics (NOT a bug)
- **What:** [src/FinVM/Numeric/Fixed.purs:61-68](../src/FinVM/Numeric/Fixed.purs#L61-L68). `div` computes `(a.value · 10^b.scale) / b.value` and returns the result at **`a.scale`** (the dividend's scale). This is mathematically correct; `1/2` at scale 0 → `0` is correct integer-scale truncation, not a bug.
- **Why it's here:** The behavior is unintuitive and undocumented, and an automated audit mistook it for a defect. Lock it in.
- **Fix:** Add a doc comment on `div` stating "result scale = dividend scale; widen the dividend's scale first for more precision," and add tests covering: scale-0/scale-0, asymmetric scales, and each `Rounding` mode (`RoundDown/Up/TowardZero/AwayFromZero/HalfEven`) including negative operands.

### 7. 🔵 Defensive silent-drop fallbacks
- **What:** `writeReg` ([src/FinVM/Interpreter.purs](../src/FinVM/Interpreter.purs), `Array.updateAt` → `Nothing -> p`) and the argument-into-register fold (`fromMaybe acc`) silently no-op on out-of-bounds indices. Today these are unreachable because [src/FinVM/Validate.purs](../src/FinVM/Validate.purs) bounds-checks registers before execution.
- **Why it matters:** If validation is ever bypassed or a `Program` is constructed in-process, a corrupt write becomes an invisible wrong answer instead of a loud error.
- **Fix (low priority):** Convert these `Nothing` branches into an explicit `RegisterOutOfBounds` VM error rather than a silent skip. Cheap insurance for a "deterministic VM" whose whole value is trustworthy output.

---

## P3 — Database / Cache FFI security & determinism

### 8. 🟠 `db.hash` uses a weak 32-bit non-cryptographic hash, inconsistent with the rest of the system
- **What:** [src/FinVM/FFI/Database.js:239-252](../src/FinVM/FFI/Database.js#L239-L252) hashes a table with a DJB2-style 32-bit rolling hash (`((hash << 5) - hash) + c; hash |= 0`) and returns it as hex.
- **Why it matters:** The VM elsewhere advertises and uses **SHA-256 canonical hashing** ([src/FinVM/Encoding/Canonical.purs](../src/FinVM/Encoding/Canonical.purs)) and `LLM.txt` describes `db.hash@1` as a "Deterministic checksum of table" for proof-of-state. A 32-bit hash has trivial collision probability and is not suitable for integrity/proof use. It also relies on `JSON.stringify` key order rather than a defined canonical form.
- **Fix:** Replace with SHA-256 over a **canonical** serialization: sort rows by id, canonicalize each record's keys (reuse the canonical-encoding rules), then `crypto.subtle.digest('SHA-256', ...)`. Add a determinism test that builds the same logical table via different insertion orders and asserts identical hashes.

### 9. 🟠 Database encryption uses no key-derivation function
- **What:** [src/FinVM/FFI/Database.js:21-31](../src/FinVM/FFI/Database.js#L21-L31) derives the AES-GCM key by `keyString.padEnd(32,'0').substring(0,32)` — raw/padded bytes, no salt, no KDF.
- **Why it matters:** Weak/short keys map directly to weak key material; "encrypted" is overstated for anything security-sensitive. (Note: AES-GCM usage itself is fine — fresh 12-byte random IV per commit, GCM provides authentication.)
- **Fix:** Derive the key with PBKDF2 (or SHA-256 of `salt || key` at minimum) using a stored per-database random salt; import the derived bits as the AES-GCM key. Document the threat model in [docs/DATABASE.md](DATABASE.md). Add a test that a short passphrase still yields a full-entropy-shaped key and that wrong-key decrypt fails cleanly (the GCM tag already enforces this).

### 10. 🟡 Harden query matching against `$`/`__proto__` keys
- **What:** [src/FinVM/FFI/Database.js](../src/FinVM/FFI/Database.js) `db.query` iterates `Object.keys(query)` and reads `content[field]`. Inputs flow from typed PureScript `VRecord`s today (low real risk), but the JS layer is also directly callable.
- **Fix:** Skip/whitelist keys (`__proto__`, `constructor`, `prototype`), use `Object.hasOwn`/`Map` lookups, and only treat a value as an operator object when keys are in the known `$gt/$lt/$eq/...` set. Add a regression test with a `__proto__` query key.

### 11. 🔵 Document Cache FFI non-determinism boundary
- **What:** [src/FinVM/FFI/Cache.js](../src/FinVM/FFI/Cache.js) is an in-memory, non-persisted RAM cache. It is observable VM state but is fine for a cache; the risk is a program relying on cache contents for *core logic* and breaking the VM's determinism guarantee across runs.
- **Fix:** Document in [docs/DATABASE.md](DATABASE.md)/`LLM.txt` that cache is a non-deterministic performance aid and must not influence program output; consider excluding cache from snapshot/replay state (verify [src/FinVM/Encoding/Snapshot.purs](../src/FinVM/Encoding/Snapshot.purs) does not hash cache contents).

---

## P4 — Test coverage gaps

### 12. 🟡 Add tests for under-covered correctness paths
Current suite is solid for happy paths but thin on edges. Add:
- **Fixed-point:** division across scale boundaries and all 5 rounding modes, negative operands, `mul` scale growth (see item 6).
- **JSON round-trip:** encode→decode for `VFixed` and `VRational` (currently untested in [src/FinVM/Encoding/Json.purs](../src/FinVM/Encoding/Json.purs)), plus malformed-program decode errors.
- **DB hash determinism:** same data, different insertion order → equal hash (after item 8).
- **modPow:** no-inverse negative-exponent case returns an error (after item 5).
- **Resource limits:** assert each limit in [src/FinVM/Limits.purs](../src/FinVM/Limits.purs) actually trips its VM error (maxSteps, maxFrames/maxCallDepth, maxProcesses, maxMailboxSize, maxStateEntries, maxListLength) — guards against silent regressions.

### 13. 🔵 Monitor/link cleanup on process death
- **What:** Monitor refs and links accumulate; dead-process monitor entries are not pruned ([src/FinVM/Interpreter.purs](../src/FinVM/Interpreter.purs) `PROC_MONITOR`/`NODE_MONITOR`).
- **Why:** Slow memory growth for long-lived supervisors monitoring many short-lived children. Matches a known Erlang-semantics edge, not a crash.
- **Fix:** On process completion, emit DOWN notifications and drop stale monitor entries; add a test.

---

## Suggested execution order
1. **P0 #1–#2** (git init + README) — unblocks CI and onboarding immediately.
2. **P1 #4** (CLI exit codes) — small, high-value correctness fix.
3. **P2 #5** + **P4 #12 modPow/Fixed tests** — numeric trustworthiness.
4. **P3 #8–#9** (db hash → SHA-256, KDF) — security/integrity.
5. Remaining P3/P4 polish.

Each item is independently shippable; none requires a rewrite. Recommend one branch + PR per group so the (newly enabled) CI gates each change.
