# Task: decide which of these mutants are worth running

Another agent planted mutants in a libsecp256k1 file and claims each one is a
plausible bug that the test suite would miss. Their manifest is in
`$IN_MUTANTS` and their patches are in `$PATCH_DIR`. You did not generate them
and you owe their author nothing. Your only job is to decide, mutant by mutant,
whether it is worth the machine time to compile and test.

Running a mutant costs a library build plus the unit, exhaustive, and
constant-time suites. An equivalent mutant burns that for a guaranteed
non-result, a mutant that does not compile burns it for nothing at all, and a
mutant the first unit test kills teaches nobody anything. Your verdicts are
what decides where that budget goes.

Your inputs:

- `$IN_MUTANTS` - the mutants to judge.
- `$PATCH_DIR` - the patch for each, named `<id>.patch`.
- `$BITCOIN_SRC` - the libsecp256k1 tree the patches were cut against, clean.
  The directory name is historical; it is not Bitcoin Core.
- `$BIPS_SRC` - a full clone of `bitcoin/bips`, for when a claimed spec
  violation turns on what a BIP actually says.

You are in a disposable container with full permissions. Read anything, run
anything. Do not build the library; static reading is enough. You may apply a
patch to look at it in context, but revert it with
`git -C $BITCOIN_SRC checkout -- <file>` before moving on, and leave the tree
clean when you finish.

Keep in mind how this library is built: almost all code is headers included
into `src/secp256k1.c`, which `src/tests.c` includes; only one field/scalar
implementation is compiled per platform (`field_5x52`, `scalar_4x64` on
x86_64); and code under `#ifdef VERIFY` or inside `VERIFY_CHECK(...)` exists
only in the test binaries.

## Method

For each mutant, in order:

1. **Read the patch itself.** Not the manifest's description of it. `original`
   and `mutated` in the manifest are the author's account of their own change
   and may not match the diff. Open `$PATCH_DIR/<id>.patch`, and read the
   surrounding code in `$BITCOIN_SRC` with enough context to know what the
   function does: the callers up to the public API, what the early returns
   skip.

2. **Decide whether it compiles.** If the mutant carries `compiles_ok`, that is
   the compiler's answer, not a claim: the harness applied the patch and
   syntax-checked the units that include the file. Take it, and spend nothing
   more on the question - a `false` there makes the mutant `invalid`, and
   `compile_error` says why. Where the field is absent no check was available,
   so read for it instead: every name declared and in scope at its new
   position, types still matching, every path still returning a value.

3. **Decide whether it changes behaviour.** Construct, concretely, an API call
   sequence and input that reaches the mutated line and diverges: what the
   original returns or writes versus the mutant. If you cannot construct one,
   ask why:
   - is the line in a platform or `#if` branch this build does not compile;
   - is it only in `VERIFY` code, so the shipped library is unchanged;
   - is the value normalized, reduced, or overwritten before anyone reads it;
   - is a magnitude or range bound that the mutant relaxes never reached;
   - does an earlier `ARG_CHECK` or a later check already reject every input
     the mutant would let through?
   Any of those makes it equivalent in practice, whatever the manifest claims.
   A `constant-time` mutant is not equivalent just because every output is the
   same: a new secret-dependent branch or memory access is the behaviour
   change. It is equivalent only if the data it branches on is public.

4. **Decide whether a test kills it.** This is where most of your budget goes,
   and you must search for yourself rather than trust `kill_prediction`. grep
   `src/tests.c`, `src/modules/*/tests_impl.h`, `src/tests_exhaustive.c`,
   `src/modules/*/tests_exhaustive_impl.h`, the vectors in
   `src/modules/*/vectors.h` and `src/wycheproof/`, and `src/ctime_tests.c` for
   the functions, the API calls, and the behaviour the mutant changes.
   Remember that `VERIFY_CHECK`s are live in the test binaries: a mutant that
   breaks an invariant a `VERIFY_CHECK` downstream asserts is killed by any
   test that reaches it. A constant-time mutant is killed only if
   `ctime_tests.c` calls an API function that reaches it with secret data.
   Name the test file and case you found.

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
  you recall about libsecp256k1 - the files in front of you are the only
  authority.
- A mutant the harness already marked `"apply_ok": false` or
  `"compiles_ok": false` is `invalid`; say so in `verdict_reason` and move on
  without spending budget on it.
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
