# Task: decide which of these mutants are worth running

Another agent planted mutants in a Bitcoin Core file and claims each one is a
plausible bug that the test suite would miss. Their manifest is in
`$IN_MUTANTS` and their patches are in `$PATCH_DIR`. You did not generate them
and you owe their author nothing. Your only job is to decide, mutant by mutant,
whether it is worth the machine time to compile and test.

Running a mutant is expensive: a Core build plus a test run each. An equivalent
mutant burns that for a guaranteed non-result, a mutant that does not compile
burns it for nothing at all, and a mutant the first unit test kills teaches
nobody anything. Your verdicts are what decides where that budget goes.

Your inputs:

- `$IN_MUTANTS` - the mutants to judge.
- `$PATCH_DIR` - the patch for each, named `<id>.patch`.
- `$BITCOIN_SRC` - the Core tree the patches were cut against, clean.
- `$BIPS_SRC` - a full clone of `bitcoin/bips`, for when a claimed spec
  violation turns on what a BIP actually says.

You are in a disposable container with full permissions. Read anything, run
anything. Do not build the node; static reading is enough and a build would burn
your whole budget. You may apply a patch to look at it in context, but revert it
with `git -C $BITCOIN_SRC checkout -- <file>` before moving on, and leave the
tree clean when you finish.

## Method

For each mutant, in order:

1. **Read the patch itself.** Not the manifest's description of it. `original`
   and `mutated` in the manifest are the author's account of their own change
   and may not match the diff. Open `$PATCH_DIR/<id>.patch`, and read the
   surrounding code in `$BITCOIN_SRC` with enough context to know what the
   function does: the enclosing scope, the callers, what the early returns skip.

2. **Decide whether it compiles.** This is the cheapest way to disqualify one.
   Check every name the mutated code uses is declared and in scope at its new
   position, that types still match, that every path still returns a value, that
   nothing is used after a `std::move` the relocation introduced, that a
   relocated statement did not escape the lifetime of what it references, and
   that lock annotations are not obviously violated. Reason statically; do not
   attempt a build.

3. **Decide whether it changes behaviour.** Construct, concretely, an input that
   reaches the mutated line and diverges: which message, transaction, block,
   script, or RPC call, and what the original does with it versus the mutant. If
   you cannot construct one, ask why: is the mutated line unreachable, is the
   changed value never read, does a later check already reject everything the
   mutant would let through, does an assert make the state impossible? Any of
   those makes it equivalent in practice, whatever the manifest claims.

4. **Decide whether a test kills it.** This is where most of your budget goes,
   and you must search for yourself rather than trust `kill_prediction`. Grep
   `src/test/`, `src/test/fuzz/`, and `test/functional/` for the function names,
   the constants, the error strings, and the behaviour the mutant changes. A
   fuzz target that reaches the line with an assert on the invariant kills it. A
   functional test that asserts the exact reject reason kills a mutant that
   changes which error is returned. Name the test file and case you found.

5. **Judge.** Assign exactly one verdict:
   - `sneaky` - compiles, reachable, changes behaviour, and you could not find a
     test that catches it. Worth running. This is the valuable outcome.
   - `likely-killed` - real and valid, but you found the test that kills it.
     Name it.
   - `equivalent` - compiles, but no reachable input behaves differently.
   - `invalid` - would not compile, the patch does not match what the manifest
     claims, or the diff is empty or malformed.

Being wrong in either direction costs the same. Do not call a mutant sneaky to
be agreeable, and do not dismiss one as equivalent because tracing its
reachability is tedious. Either way you must name the file and lines that
settled it.

## Rules

- Never add a mutant. Anything you think would have been a better mutation is
  out of scope.
- Never drop a mutant, including ones you call invalid. Every input id must
  appear in the output exactly once, with all of its original fields unchanged.
- Read every line you cite. Cite nothing from memory, and do not lean on what
  you recall about Core - the files in front of you are the only authority.
- A mutant the harness already marked `"apply_ok": false` is `invalid`; say so
  in `verdict_reason` and move on without spending budget on it.
- If a mutant is marked `duplicate_of`, judge it on its merits but say in
  `verdict_reason` that it duplicates that id.

## Output

Write `$OUT_REVIEWED`: the object from `$IN_MUTANTS`, unchanged except that
every entry in `mutants` gains exactly these fields:

```json
{
  "verdict": "sneaky | likely-killed | equivalent | invalid",
  "compiles": true,
  "reachable": true,
  "killed_by": "test file and case that kills it, or 'none found'",
  "verdict_reason": "2-4 sentences: the input you constructed, what diverges, and the tests you searched. Name the files and lines you read, especially when they are not the ones the mutant cited."
}
```

Nothing else in that file: no markdown fences, no prose, no new top-level keys.
Validate with `jq empty $OUT_REVIEWED` before you finish, confirm the mutant
count matches the input, and confirm `git -C $BITCOIN_SRC status --porcelain` is
empty. Your final chat message should be one line per mutant: id, verdict, and a
few words of why.
