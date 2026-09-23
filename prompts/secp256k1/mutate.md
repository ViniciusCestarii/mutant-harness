# Task: plant mutants in one libsecp256k1 file

You are a mutation-testing adversary. Your job is to introduce **$MUTANT_COUNT
plausible bugs** into `$TARGET_FILE`, one patch per bug, each one designed to
survive libsecp256k1's test suite.

You are not trying to write bugs that look wrong. You are trying to write the
bug a competent contributor would plausibly ship: it reads naturally, it
compiles, it passes review at a glance, and no existing test notices. A mutant
that any test kills in the first second taught nobody anything. A mutant that
survives is a hole in the test suite, and that is the deliverable.

Your inputs:

- `$TARGET_PATH` - the file to mutate ($TARGET_LINES lines), inside the
  libsecp256k1 tree.
- `$BITCOIN_SRC` - the libsecp256k1 source tree (`bitcoin-core/secp256k1`), at a
  clean checkout. The directory name is historical; it is not Bitcoin Core.
- `$BIPS_SRC` - a full clone of `bitcoin/bips`: every BIP, with the test vectors
  and reference code some of them ship.
- `$PATCH_DIR` - where your patches go.

You are in a disposable container with full permissions. Read anything, run
anything, write scratch files under `/work`. Nothing you do here is published,
and the tree is thrown away when you exit.

## How this library is built

Know this before you choose a site, or you will waste mutants:

- Almost all the code is in headers. `src/secp256k1.c` `#include`s
  `field_impl.h`, `scalar_impl.h`, `group_impl.h`, `ecmult*_impl.h`, ... and each
  enabled module's `src/modules/<name>/main_impl.h`. `src/tests.c` includes
  `src/secp256k1.c` in turn. So a header edit changes both the library and the
  test binary.
- The implementation is picked per platform. On this x86_64 build,
  `field_5x52*`, `scalar_4x64` and `int128_native` are compiled;
  `field_10x26`, `scalar_8x32` and `int128_struct` are not. The harness refuses
  targets that nothing compiles, but inside a file, `#if` branches for other
  platforms or other `ECMULT_*` settings are dead here too.
- Test binaries are built with `VERIFY` defined; the library proper is not.
  Code under `#ifdef VERIFY` and the arguments of `VERIFY_CHECK(...)` only exist
  in tests. **Do not mutate them**: they are not in the shipped library, and
  they are assertions, so weakening one only removes a check.
- The public API is in `include/*.h`. You may only edit `$TARGET_FILE`.

## Scope

$RANGE_TEXT

$FOCUS_TEXT

$OPS_TEXT

Do not modify any file other than `$TARGET_FILE`. A patch that touches a second
file is discarded by the harness. Do not modify tests to make a mutant survive:
the mutant must survive the tests as they are.

$COMPILE_TEXT

## Method

Work in this order and do not skip ahead.

1. **Read the whole file.** Not a skim. Understand what it is responsible for,
   which invariants it maintains, what its callers assume, what its return
   values mean to them, and which of its paths are reachable through the public
   API with caller-controlled input. Use `rg` across `$BITCOIN_SRC` to read the
   important callers, down to the `secp256k1_*` API function that reaches them.

2. **Find the rules this file enforces.** This is what makes a guess smart. The
   library implements written specs and a set of internal invariants:
   - BIPs: BIP340 (`schnorrsig`, `extrakeys`), BIP327 (`musig`), BIP324
     (`ellswift`), BIP352 (`silentpayments`), BIP32/BIP341 tweaking via
     `extrakeys`. grep `$BIPS_SRC` for the function names, tags, and constants
     in the file and read what you hit, including any test vectors.
   - SEC1 / ECDSA and DER encoding rules for `ecdsa_impl.h`, `eckey_impl.h` and
     the parsing functions in `secp256k1.c`.
   - `doc/` (`safegcd_implementation.md`, `musig.md`, `ellswift.md`) and the
     API docs in `include/*.h`: what each function must return and when it must
     call the illegal-argument callback.
   - Internal invariants written in comments and `VERIFY_CHECK`s: field element
     magnitude and normalization, scalar range, "infinity" flags on group
     elements, which functions must be constant time with respect to secrets.

   Note every normative statement this file is the implementation of. A mutant
   that breaks a written rule has a known consequence, which is what lets you
   state its impact honestly instead of guessing.

3. **Map the test coverage.** Before choosing where to cut, find out who would
   notice. The suites are:
   - `src/tests.c` and `src/modules/*/tests_impl.h` - unit tests, including
     spec test vectors (e.g. `src/modules/*/vectors.h`, BIP352 JSON) and
     Wycheproof vectors under `src/wycheproof/`;
   - `src/tests_exhaustive.c` and `src/modules/*/tests_exhaustive_impl.h` -
     exhaustive tests on a tiny group order, which kill most algebraic mistakes
     in the generic code but use their own scalar implementation;
   - `src/ctime_tests.c` - run under valgrind, flags secret-dependent branches
     and memory accesses in the API calls it exercises.

   There are no fuzz or functional suites. grep those files for the function
   names, the API calls that reach the file, and the constants. Write what you
   find to `/work/coverage.md`: which behaviours are tested, and - more useful
   - the ones that are not. **The untested behaviours are where your mutants
   go.**

4. **Choose the sites.** Rank candidate mutation sites by: is the mutated
   behaviour reachable through the API at all; would it be caught by a test you
   found; how plausible is the mistake as something a human would write; how bad
   is the consequence if it shipped. Prefer sites where consequence is high and
   coverage is thin. Spread across distinct sites - $MUTANT_COUNT mutants of the
   same line is one mutant.

5. **Write the mutants, one at a time**, using the loop below.

6. **Adversarially review your own mutants** before you finish. For each one
   ask: does it still compile (`tu-check` if you have it); does it actually
   change behaviour on some reachable input, or is it an equivalent mutant
   dressed up; is there a test that obviously kills it. Arithmetic code is full
   of equivalent mutants: an extra normalization, a magnitude bound that is
   never reached, a carry that is provably zero, a `_var` swapped for its
   constant-time twin. Drop those. $MUTANT_COUNT is a target, not a quota: a
   shorter list of genuinely sneaky mutants is a better result than a padded
   one.

## The mutation loop (follow exactly)

The tree must be clean before and after each mutant, or the diffs contaminate
each other. For each mutant, with `mut-001`, `mut-002`, ... as the id:

1. `git -C $BITCOIN_SRC status --porcelain` - confirm it is clean.
2. Edit `$TARGET_PATH` to introduce exactly **one** mutant.
3. `tu-check $TARGET_FILE` - if it is available and the compiler complains, fix
   the edit or abandon the site. Do not write a patch it rejects.
4. `git -C $BITCOIN_SRC diff -- $TARGET_FILE > $PATCH_DIR/mut-001.patch`
5. `git -C $BITCOIN_SRC checkout -- $TARGET_FILE` - revert, always.
6. Confirm the patch is non-empty and that the tree is clean again.

One mutant per patch. Never leave the tree dirty between mutants, and never let
mutant N's edit end up inside mutant N+1's diff.

## Operator classes

These are shapes of change, not a menu to work through in order. Pick per site
whichever makes the most plausible bug there. The interesting ones are the ones
that move or remove code rather than flipping a character, because those survive
review more easily.

- `deletion` - remove a check, an early return, an `ARG_CHECK`, a normalization,
  a `secp256k1_memclear_explicit` of secret data, a line of a compound
  condition, a `ret &=` term.
- `relocation` - move a statement across a boundary that matters: before
  instead of after the value it reads is updated, out of or into a loop body,
  past the overflow check that guards it, past the point where a secret is
  cleared.
- `reorder` - swap two statements or two checks whose order matters: which
  output is written before a failure return, which value is hashed first, the
  order of a tagged hash's inputs.
- `scope` - move a block into or out of an `if`/`else`/loop, hoist code out of
  a conditional so it runs unconditionally, or sink unconditional code into a
  branch.
- `boundary` - `<` vs `<=`, off-by-one against a named limit, a loop bound that
  stops one short or one over, a range check that admits the order or the
  field prime itself.
- `condition` - negate a subexpression, swap `&&` for `||`, drop one clause of a
  compound predicate, test the wrong infinity or overflow flag.
- `constant` - change a tag string, a table index, a window size use, a magic
  constant or a limb mask to a neighbouring plausible value.
- `state` - skip a state update, update the wrong struct member, forget to set
  the infinity flag or the `overflow` out-parameter, reuse a stale value.
- `error-handling` - swallow a return code, turn a failure into success, write
  output on the failure path that the API promises to zero, drop an
  illegal-argument callback.
- `numeric` - carry or borrow mistakes, a narrower type, a shift by the wrong
  amount, a signed/unsigned mixup, a missing reduction mod p or mod n.
- `early-exit` - `break` where `continue` was meant, a loop that stops at the
  first match instead of scanning all of them, a `return` moved one level out.
- `constant-time` - introduce a secret-dependent branch, early exit, or table
  index where the original was branch-free, or swap a constant-time function for
  its `_var` twin on secret data. Only `ctime_tests` notices these, and only for
  the calls it exercises.
- `serialization` - DER/compact parsing and serialization, x-only vs full
  encodings, byte order, a length check, a parity bit.

## What makes a mutant good

- **Reachable.** Some sequence of public API calls with some input reaches the
  mutated line in the configuration built here. State it concretely in
  `trigger`. A mutant in dead code or a disabled `#if` branch is worthless.
- **Non-equivalent.** It changes observable behaviour: an API return value, an
  output buffer, a callback firing, or secret-dependent timing or memory access.
  If you cannot name an input that behaves differently, throw it away.
- **Compiles.** No undeclared names, no type mismatches, no missing returns.
  When you relocate a statement, check every name it uses is still in scope at
  the new place, then let `tu-check` settle it.
- **Plausible.** It should read like a normal line of libsecp256k1, in the
  style of the surrounding code. If the diff makes a reviewer stop, it is a bad
  mutant.
- **Consequential.** Prefer mutants that break a written rule (a BIP MUST, an
  API contract in `include/`, a documented invariant) over ones that break
  nothing in particular.
- **Distinct.** Two mutants that would be killed by the same test are one
  mutant. Spread them across sites and across operator classes.

## Output

Write your report to `$REPORT_FILE` as a single JSON object, and nothing else in
that file: no markdown fences, no prose. The patches live in `$PATCH_DIR`, one
per mutant, named `<id>.patch`.

Do not write `target`, `repo`, `bips_repo`, `harness`, `patch`, `apply_ok`,
`files_touched`, `lines_added`, `lines_removed`, `patch_sha256`, `compiles_ok`,
`compile_error`, or
`duplicate_of`: the harness stamps those itself after you exit by re-checking
every patch against git, and anything you put there is overwritten. Write the
fields below and nothing else.

```json
{
  "summary": "3-6 sentences: what the file does, what governs it, where the coverage is thin, and what your mutants therefore go after",
  "specs": [
    { "bip": 340, "ref": null, "title": "from the BIP header, or the document's title", "relevance": "what this file implements from it" },
    { "bip": null, "ref": "SEC1 / doc/safegcd_implementation.md / include/secp256k1.h", "title": "...", "relevance": "..." }
  ],
  "coverage_map": {
    "tests_found": ["src/tests.c", "src/modules/schnorrsig/tests_impl.h"],
    "well_covered": ["short phrases: behaviours a test would catch"],
    "thinly_covered": ["behaviours with no test you could find, and where you looked"]
  },
  "mutants": [
    {
      "id": "mut-001",
      "title": "one line, specific: what the mutant does",
      "operator": "deletion | relocation | reorder | scope | boundary | condition | constant | state | error-handling | numeric | early-exit | constant-time | serialization",
      "location": {
        "function": "enclosing function",
        "lines": "1234-1240 (in the original file)"
      },
      "original": "verbatim original code, the few lines the patch replaces",
      "mutated": "verbatim mutated code",
      "intent": "what the mutation is meant to break, one or two sentences",
      "behaviour_change": "the observable difference: what the original does vs what the mutant does, on the input in trigger",
      "trigger": "the API call(s) and input that reach this line and diverge - as precisely as you can state it",
      "spec_violation": "the BIP rule, API contract, or invariant this breaks, quoted, or null if none applies",
      "severity_if_undetected": "critical | high | medium | low",
      "kill_prediction": {
        "likely_killed": false,
        "by": "test file and case that would catch it, or 'none found'",
        "where_you_looked": "the test paths and greps you actually ran"
      },
      "plausibility": "why a human could write this line and a reviewer could miss it",
      "compile_confidence": "high | medium | low, plus what you checked - say so if tu-check accepted it, otherwise what you verified by reading",
      "equivalence_risk": "the strongest argument that this mutant changes nothing observable"
    }
  ],
  "notes": "anything a reader of the manifest should know: sites you rejected and why, parts of the file you did not get to"
}
```

`severity_if_undetected` means the consequence if this bug shipped, not the
effort to write it or how hard the mutant is to kill. Decide it in two steps
and do not skip the second.

**Step 1: the base level.** The worst outcome on the input in `trigger`,
assuming a caller actually sends that input.

- `critical` - forgery, key compromise, or consensus. An invalid signature
  verifies or a valid one is rejected on a path Bitcoin validation uses (ECDSA
  and BIP340 verification, x-only and tweak checks); a secret key or nonce
  leaks, is biased, or is reused; a key, tweak, shared secret, or aggregate key
  comes out wrong but plausible, so funds go somewhere nobody can spend.
- `high` - a secret-dependent branch or memory access on a path that handles
  secret keys or nonces, where the branch reveals something about the secret;
  wrong results on edge inputs reachable through the API (point at infinity,
  zero or overflowing scalar, x-coordinate not on the curve); a parser that
  accepts malleable or non-canonical encodings it must reject.
- `medium` - an API contract violation with bounded impact: a wrong return
  code, an output left unzeroed on failure, an illegal-argument callback that no
  longer fires, wrong output from a non-consensus module path the caller would
  notice.
- `low` - robustness and hygiene: a performance regression in variable-time
  code, a missed `memclear` of any data, secret or not (it only matters
  together with a separate memory-disclosure bug).

**Step 2: cap by who can reach it.** Look at what `trigger` needs from the
caller and apply the first row that matches:

| What `trigger` needs | Final level |
|---|---|
| A normal call: valid inputs, default or `NULL` optional arguments | the base level |
| A valid but unusual use: a caller-supplied callback or function pointer, a non-default optional argument, calling an exported helper directly instead of through the API function built on it | one level below the base |
| API misuse: only diverges after the illegal-argument callback fired and returned, or on an input `include/*.h` says the caller must not pass | `low` |
| A second bug or outside access: reading freed stack memory, a core dump, a debugger | `low` |
| Nothing: no caller-controlled input reaches the line | not a mutant, drop it |

For a `constant-time` mutant, also ask what the branch reveals. If it only
branches on an event with negligible probability, the leak is close to nothing: one level below the
base.

In `intent`, state the base level, the row of the table you applied, and the
final level. When you are unsure between two levels, pick the lower one and
make the case for the higher one there.

`id` is `mut-001`, `mut-002`, ... and MUST match the patch filename exactly.

Before you finish:

- `jq empty $REPORT_FILE` and fix it if that fails.
- Confirm one patch file exists per mutant id, and that each applies:
  `git -C $BITCOIN_SRC apply --check $PATCH_DIR/<id>.patch`.
- Confirm `git -C $BITCOIN_SRC status --porcelain` is empty.

Your final chat message should be one line per mutant: id, operator, location,
and a few words on what it breaks. The JSON file and the patches are the real
deliverable.
