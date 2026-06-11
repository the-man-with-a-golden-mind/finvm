# FinVM — Decisions (ADRs)

Architecture decision records. Each: context → decision → rationale →
consequences. Newest decisions append at the bottom. See
[IMPROVEMENT_PLAN.md](IMPROVEMENT_PLAN.md) for the change log these came from.

---
## ADR-0001 — CLI fails loudly (exit codes + clean errors)
**Context.** `finvm run` always exited 0; a missing file dumped a raw Node stack
trace; failed programs still exited 0.
**Decision.** `runJsonProgramResult` reports `{ok, output}`; `Main` sets a non-zero
exit code on `failed`/`error`, and catches file-read errors into a clean
`{status:"error"}` JSON.
**Consequence.** Scripts/CI can detect failures. Help/usage stays exit 0.

---
## ADR-0002 — `modPow` returns `Maybe`, not a `0` sentinel
**Context.** For a negative exponent with no modular inverse, `modPow` returned
`0` — indistinguishable from a real result, in a crypto builtin.
**Decision.** `modPow :: … -> Maybe BigInt`; the builtin surfaces a
`NoModularInverse` error.
**Consequence.** Compilers must handle the error path. Tested at unit + builtin
level.

---
## ADR-0003 — Fixed-point division uses the truncating pair (`quot`/`rem`)
**Context.** `roundedQuotient` mixed `Data.BigInt`'s Euclidean `/` (non-negative
remainder) with the truncating `rem`, so `q*denom + rem ≠ numerator` for negatives
→ wrong rounding for negative operands.
**Decision.** Use `quot`/`rem` consistently; document that `div` returns at the
**dividend's** scale.
**Rationale.** The rounding logic was written for truncate-toward-zero; this makes
it self-consistent. The scale convention (precision bounded by the dividend) is
predictable and documented rather than "fixed".
**Consequence.** Negative `Fixed` division changes vs. the old buggy output —
re-baseline golden tests. Covered by rounding-mode tests incl. negatives.

---
## ADR-0004 — Close the silent arg-drop in validation, not the interpreter
**Context.** A function with `registerCount < arity` silently dropped arguments
during the register fold. `writeReg`/the fold use `fromMaybe`/`Nothing -> p`
fallbacks.
**Decision.** Add `registerCount >= arity` (and non-negative) checks to
`FinVM.Validate`, rather than converting `writeReg` to `Either` across ~80 call
sites.
**Rationale.** Fixes the hole at its source; the interpreter fallbacks become
provably unreachable for validated programs without a large, risky refactor.
**Consequence.** Programs that previously "worked" with a malformed
arity/registerCount are now rejected by validation. (Note: the CLI does not run
validation — see ADR-0010.)

---
## ADR-0005 — DB integrity & secrets: SHA-256 hash, PBKDF2 KDF, query hardening
**Context.** `db.hash` used a weak 32-bit rolling hash (collision-prone, unlike the
SHA-256 used elsewhere); encryption derived the AES key by zero-padding the
passphrase; query matching iterated raw keys.
**Decision.** (a) `db.hash` = SHA-256 over canonical, id-sorted, key-canonicalized
rows; (b) AES-256-GCM key via PBKDF2-HMAC-SHA256 (210k iters) + a per-database
random salt persisted in the bundle; (c) drop `__proto__`/`constructor`/`prototype`
query keys and whitelist `$`-operators.
**Consequence.** Old `.finvm.db` files don't load (format `v:2` with `salt`). Hash
values change. Same passphrase still decrypts. Documented in
[DATABASE.md](DATABASE.md).

---
## ADR-0006 — Monitors deliver DOWN and self-clean
**Context.** A process monitoring another got no notification on its death, and
monitor entries leaked.
**Decision.** On terminal status, deliver `VVariant "DOWN" {ref,pid,reason}` to
each monitoring process (waking it if blocked) and remove the monitor entries.
**Consequence.** Erlang-like monitor semantics; bounded monitor maps.

---
## ADR-0007 — `VList` is a chunked vector (`FinVM.Vec`), not an `Array`
**Context.** `LIST_APPEND` (`Array.snoc`) copied the whole list each call →
building an N-element list was O(N²) (50k ≈ 4.3 s). The VM's list API is
index-based (`LIST_GET` by index is the only iteration primitive).
**Options considered.**
- `Data.CatList` (catenable list): O(1) append but **O(n) indexing** → makes
  `LIST_GET`-loops O(n²). Rejected — worse for this API.
- Finger tree (`Data.Sequence`): ideal (O(1) ends, O(log n) index) but **not in the
  package set**; adding it is risky. Rejected for now.
- **Chunked vector** (fixed-size blocks + partial tail): O(1) index/length,
  amortized ~O(1) append, ~O(N) to build N. **Chosen.**
**Decision.** `VList (Vec Value)`. `Eq`/`Ord`/`Show` are defined over the logical
sequence, so list comparison, canonical hashing, and display are unchanged.
**Consequence.** 50k build 4.3 s → ~0.15 s (~30×), now linear. ~27 call sites +
codec + canonical migrated. In-place mutation was rejected (lists alias via `MOVE`/
storage, so persistence is required for correctness).

---
## ADR-0008 — Accept ~140× vs native; defer the mutable execution core
**Context.** After fixing the algorithmic issues, FinVM (perf mode) is ~140× slower
than native JS + big-integer on an arithmetic loop.
**Investigation.** Measured: register-array copying is **not** the bottleneck
(time flat from registerCount 5→200). Removing a per-step `Process` allocation
(PC pre-advance) produced **no measurable speedup** and was reverted. The cost is
pervasive per-instruction interpreter overhead (immutable record rebuilds +
dispatch + monadic plumbing in compiled PureScript).
**Decision.** Accept current performance. The only material lever is rewriting the
hot loop over mutable state (`ST`/`Effect`), an est. ~2–4× for a large, risky
change that trades away the pure/auditable design — **not** undertaken.
**Consequence.** ~140× is the documented, expected number for this VM class. The
fuzz + determinism + spec harness is in place if the mutable-core rewrite is ever
pursued.

---
## ADR-0009 — `performanceMode` is reachable; keep the proof system
**Context.** The interpreter supported `performanceMode` (skip trace/proof
recording) but the JSON entry point hardcoded it to `false`. "Provability" was
suspected of being overhead.
**Decision.** Read `"performanceMode"` from the program JSON. Keep the proof
opcodes — in perf mode they only skip the trace `Cons` (≈ free), and `ASSERT`
still enforces its check.
**Consequence.** ~1.4× faster runs on demand with identical results; no need to
strip proofs for speed.

---
## ADR-0010 — Documented JSON format made to match the decoder; multi-function added
**Context.** `LLM.txt` documented a `{tag,contents}` schema and single `main`, but
the only decoder accepts a tagless/positional format, and the codec silently
decoded `VFixed`/`VRational`/`VMap` constants as `VRecord`.
**Decision.** (a) Correct `LLM.txt`/specs to the real tagless/positional format;
(b) make the value codec round-trip-safe (decode `fixed`/`rational`/`map`);
(c) add a top-level `functions` map + `entrypoint` so `CALL`/`TAIL_CALL`/
`PROC_SPAWN` resolve real functions; the simplified single-`main` form still works.
**Consequence.** Compilers can target a spec that matches reality and emit
multi-function programs (recursion verified). See
[LANGUAGE_SPEC.md](LANGUAGE_SPEC.md).

---
## ADR-0011 — Known gaps deliberately left open
These are intentional, scoped-out items (not oversights):
- **CLI does not run `validateProgram`** — programs fail at runtime, not with
  up-front validation. Wiring validation into `runJsonProgram` would improve
  diagnostics (low risk, good next step).
- **`db.*` / `cache.*` not wired into the CLI** — `Main` runs with
  `externalBuiltins: Map.empty`. The registries exist; injecting `nativeDb`/
  `nativeCache` would make the documented builtins usable from `finvm run`.
- **Only `maxSteps` is configurable from JSON** — exposing the rest of `EvalLimits`
  is a small addition.
- **No multi-function type checking** — `parameterTypes`/`returnType` default to
  `TAny`; only `arity` is enforced at call sites.
</content>
