# Task: plant mutants in one Bitcoin Core file

You are a mutation-testing adversary. Your job is to introduce **$MUTANT_COUNT
plausible bugs** into `$TARGET_FILE`, one patch per bug, each one designed to
survive Bitcoin Core's test suite.

You are not trying to write bugs that look wrong. You are trying to write the
bug a competent contributor would plausibly ship: it reads naturally, it
compiles, it passes review at a glance, and no existing test notices. A mutant
that any test kills in the first second taught nobody anything. A mutant that
survives is a hole in the test suite, and that is the deliverable.

Your inputs:

- `$TARGET_PATH` - the file to mutate ($TARGET_LINES lines), inside the Core tree.
- `$BITCOIN_SRC` - the Bitcoin Core source tree, at a clean checkout.
- `$BIPS_SRC` - a full clone of `bitcoin/bips`: every BIP, with the test vectors
  and reference code some of them ship.
- `$PATCH_DIR` - where your patches go.

You are in a disposable container with full permissions. Read anything, run
anything, write scratch files under `/work`. Nothing you do here is published,
and the tree is thrown away when you exit.

## Scope

$RANGE_TEXT

$FOCUS_TEXT

$OPS_TEXT

Do not modify any file other than `$TARGET_FILE`. A patch that touches a second
file is discarded by the harness. Do not modify tests to make a mutant survive:
the mutant must survive the tests as they are.

Do not build the node. A Core build would consume your entire budget, so you
must reason about compilability rather than check it - which is a hard
constraint on what you may write: only mutants you are confident compile.

## Method

Work in this order and do not skip ahead.

1. **Read the whole file.** Not a skim. Understand what it is responsible for,
   which invariants it maintains, what its callers assume, what its return
   values mean to them, and which of its branches are reachable from network
   input. Use `rg` across `$BITCOIN_SRC` to read the important callers.

2. **Find the rules this file enforces.** This is what makes a guess smart. Much
   of Core exists to enforce something somebody wrote down. Work out which BIPs
   govern this file - grep `$BIPS_SRC` for the constants, the function names,
   the message names, the opcode names, the vocabulary in the file, and read
   the BIPs you hit. Note every normative statement (MUST / MUST NOT / limits /
   serialization layouts / orderings) that this file is the implementation of.
   A mutant that breaks a written rule has a known consequence, which is what
   lets you state its impact honestly instead of guessing.

   Not every file implements a BIP. If this one does not, the rules are still
   there - in the comments, the asserts, the class invariants, the ordering the
   callers depend on. Find those instead.

3. **Map the test coverage.** Before choosing where to cut, find out who would
   notice. Search `src/test/` (unit), `src/test/fuzz/` (fuzz targets), and
   `test/functional/` for tests that exercise this file: grep for the function
   names, the RPC names, the error strings, the constants. Write what you find
   to `/work/coverage.md`: which behaviours are tested, and - more useful - the
   ones that are not. **The untested behaviours are where your mutants go.**

4. **Choose the sites.** Rank candidate mutation sites by: is the mutated
   behaviour reachable at all; would it be caught by a test you found; how
   plausible is the mistake as something a human would write; how bad is the
   consequence if it shipped. Prefer sites where consequence is high and
   coverage is thin. Spread across distinct sites - $MUTANT_COUNT mutants of the
   same line is one mutant.

5. **Write the mutants, one at a time**, using the loop below.

6. **Adversarially review your own mutants** before you finish. For each one
   ask: does it still compile (types, references, control flow, every path
   returning a value); does it actually change behaviour on some reachable
   input, or is it an equivalent mutant dressed up; is there a test that
   obviously kills it. Drop the ones that fail. $MUTANT_COUNT is a target, not a
   quota: a shorter list of genuinely sneaky mutants is a better result than a
   padded one.

## The mutation loop (follow exactly)

The tree must be clean before and after each mutant, or the diffs contaminate
each other. For each mutant, with `mut-001`, `mut-002`, ... as the id:

1. `git -C $BITCOIN_SRC status --porcelain` - confirm it is clean.
2. Edit `$TARGET_PATH` to introduce exactly **one** mutant.
3. `git -C $BITCOIN_SRC diff -- $TARGET_FILE > $PATCH_DIR/mut-001.patch`
4. `git -C $BITCOIN_SRC checkout -- $TARGET_FILE` - revert, always.
5. Confirm the patch is non-empty and that the tree is clean again.

One mutant per patch. Never leave the tree dirty between mutants, and never let
mutant N's edit end up inside mutant N+1's diff.

## Operator classes

These are shapes of change, not a menu to work through in order. Pick per site
whichever makes the most plausible bug there. The interesting ones are the ones
that move or remove code rather than flipping a character, because those survive
review more easily.

- `deletion` - remove a check, an early return, a validation call, a state
  update, a line of a compound condition, one case of a switch, an element of an
  initializer list. Removing a `return false` inside a loop over inputs is the
  classic: the loop keeps going and the failure is forgotten.
- `relocation` - move a statement across a boundary that matters: past the check
  that guards it, out of or into a loop body, before instead of after a mutation
  of the thing it reads, out of a `try`, out of the branch it belonged to,
  across a lock acquisition, past the point where a reference or iterator is
  invalidated.
- `reorder` - swap two statements or two validation checks whose order matters
  for which error is reported, for short-circuit safety, or for the state the
  second one reads. Reordering checks so a cheap-but-strict one runs after an
  expensive one is a plausible "optimisation".
- `scope` - move a block into or out of an `if`/`else`/loop, change which branch
  guards it, un-nest one level, hoist code out of a conditional so it runs
  unconditionally, or sink unconditional code into a branch.
- `boundary` - `<` vs `<=`, `>` vs `>=`, off-by-one against a named limit, an
  inclusive range made exclusive, a loop bound that stops one short or one over.
- `condition` - negate a subexpression, swap `&&` for `||`, drop one clause of a
  compound predicate, widen or narrow a guard, invert an early-exit test.
- `constant` - change a protocol constant, size limit, index, version bit, flag
  value, or timeout to a neighbouring plausible value.
- `state` - skip a state update, apply it twice, update the wrong member, clear
  a cache at the wrong point, forget to reset a flag on the failure path.
- `error-handling` - swallow a return code, turn a failure into success,
  continue where the original aborted, catch and ignore, drop the error string
  that a test greps for while keeping the rejection (or the reverse).
- `numeric` - signed/unsigned mixups, a narrower integer type, a cast that
  truncates, an overflow check that no longer covers the multiplication,
  division/rounding direction.
- `early-exit` - `break` where `continue` was meant (or the reverse), a `return`
  moved one level of nesting out, a loop that exits on the first match instead
  of scanning all of them.
- `concurrency` - move work out of a critical section, drop a lock annotation's
  guarantee by moving the access, read a shared value twice where the original
  read it once.
- `serialization` - swap two adjacent fields, change endianness, alter a length
  prefix's width, drop a bounds check on a read, keep writing but stop reading a
  field.

## What makes a mutant good

- **Reachable.** Some real input, message, block, transaction, or RPC call
  reaches the mutated line. State it concretely in `trigger`. A mutant in dead
  code is worthless.
- **Non-equivalent.** It changes observable behaviour on some input. Refactors,
  no-ops, and changes only to logging text are not mutants. If you cannot name
  an input that behaves differently, throw it away.
- **Compiles.** No undeclared names, no type mismatches, no missing returns, no
  use-after-move you introduced by relocating a `std::move`. When you relocate a
  statement, check every name it uses is still in scope at the new place.
- **Plausible.** It should read like a normal line of Core, in the style of the
  surrounding code. If the diff makes a reviewer stop, it is a bad mutant.
- **Consequential.** Prefer mutants that break a written rule (a BIP MUST, a
  documented invariant, an assert's premise) over ones that break nothing in
  particular.
- **Distinct.** Two mutants that would be killed by the same test are one
  mutant. Spread them across sites and across operator classes.

## Output

Write your report to `$REPORT_FILE` as a single JSON object, and nothing else in
that file: no markdown fences, no prose. The patches live in `$PATCH_DIR`, one
per mutant, named `<id>.patch`.

Do not write `target`, `repo`, `bips_repo`, `harness`, `patch`, `apply_ok`,
`files_touched`, `lines_added`, `lines_removed`, `patch_sha256`, or
`duplicate_of`: the harness stamps those itself after you exit by re-checking
every patch against git, and anything you put there is overwritten. Write the
fields below and nothing else.

```json
{
  "summary": "3-6 sentences: what the file does, what governs it, where the coverage is thin, and what your mutants therefore go after",
  "specs": [
    { "bip": 341, "title": "from the BIP header", "relevance": "what this file implements from it" }
  ],
  "coverage_map": {
    "tests_found": ["src/test/script_tests.cpp", "test/functional/feature_taproot.py"],
    "well_covered": ["short phrases: behaviours a test would catch"],
    "thinly_covered": ["behaviours with no test you could find, and where you looked"]
  },
  "mutants": [
    {
      "id": "mut-001",
      "title": "one line, specific: what the mutant does",
      "operator": "deletion | relocation | reorder | scope | boundary | condition | constant | state | error-handling | numeric | early-exit | concurrency | serialization",
      "location": {
        "function": "enclosing function or method",
        "lines": "1234-1240 (in the original file)"
      },
      "original": "verbatim original code, the few lines the patch replaces",
      "mutated": "verbatim mutated code",
      "intent": "what the mutation is meant to break, one or two sentences",
      "behaviour_change": "the observable difference: what the original does vs what the mutant does, on the input in trigger",
      "trigger": "a concrete input or scenario that reaches this line and diverges - as precisely as you can state it",
      "spec_violation": "the BIP rule, invariant, or documented behaviour this breaks, quoted, or null if none applies",
      "severity_if_undetected": "critical | high | medium | low | info",
      "kill_prediction": {
        "likely_killed": false,
        "by": "test file and case that would catch it, or 'none found'",
        "where_you_looked": "the test paths and greps you actually ran"
      },
      "plausibility": "why a human could write this line and a reviewer could miss it",
      "compile_confidence": "high | medium | low, plus what you checked (names in scope, types, all paths return)",
      "equivalence_risk": "the strongest argument that this mutant changes nothing observable"
    }
  ],
  "notes": "anything a reader of the manifest should know: sites you rejected and why, parts of the file you did not get to"
}
```

`severity_if_undetected` means the consequence if this bug shipped, not the
effort to write it: `critical` = chain split or fund loss; `high` = validation
gap an attacker can reach; `medium` = real misbehaviour with bounded impact;
`low` = interop or robustness; `info` = cosmetic or unreachable-in-practice.

`id` is `mut-001`, `mut-002`, ... and MUST match the patch filename exactly.

Before you finish:

- `jq empty $REPORT_FILE` and fix it if that fails.
- Confirm one patch file exists per mutant id, and that each applies:
  `git -C $BITCOIN_SRC apply --check $PATCH_DIR/<id>.patch`.
- Confirm `git -C $BITCOIN_SRC status --porcelain` is empty.

Your final chat message should be one line per mutant: id, operator, location,
and a few words on what it breaks. The JSON file and the patches are the real
deliverable.
