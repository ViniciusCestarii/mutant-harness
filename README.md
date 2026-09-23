# mutant-harness

Runs Claude Code inside a throwaway Docker container to read **one Bitcoin Core
file**, work out what it is responsible for and who tests it, and plant a set of
**plausible bugs** in it. You get one `git`-applicable patch per mutant plus a
manifest saying what each one breaks and why the test suite probably will not
notice.

```
mutant-harness --file src/script/interpreter.cpp
mutant-harness --file src/net_processing.cpp --count 20 --focus "compact blocks"
mutant-harness --target secp256k1 --file src/modules/schnorrsig/main_impl.h
```

It also runs on [libsecp256k1](#targets). That starts a container holding a clone of Bitcoin Core *and* a full clone of
`bitcoin/bips`, points the agent at the file you named, gives it full
permissions inside the container, and writes
`results/src-script-interpreter-cpp-<timestamp>/out/mutants.json` alongside
`out/patches/mut-001.patch`, `mut-002.patch`, ...

## Why an agent and not an operator table

Mechanical mutation tools (including [`bcore-mutation`](../bcore-mutation)) operate
at the individual-line level, applying predefined transformations such as changing 
`<` to `<=` or deleting a statement. They do not consider entire blocks of code or 
use semantic heuristics to determine which mutations are meaningful.

This harness makes the opposite trade. It reads the file, greps the BIPs the
file implements, greps the tests that cover it, and then **guesses** - a small
number of mutants aimed at the places where the consequence is high and the
coverage is thin. It can move a statement past the check that guards it, hoist a
block out of its branch, reorder two validations, or drop the one `return false`
inside a loop - shapes a pattern matcher does not reach for.

The best approach is to use both approachs.

## What it produces

Each mutant is a one-change patch against a known Core commit, carrying:

| field | meaning |
| --- | --- |
| `operator` | the shape of the change (see below) |
| `location` | function and line range in the original file |
| `intent` | what the mutation is meant to break |
| `behaviour_change` | what the original does vs the mutant, on `trigger` |
| `trigger` | a concrete input that reaches the line and diverges |
| `spec_violation` | the BIP rule or invariant it breaks, quoted, or null |
| `severity_if_undetected` | consequence if this bug shipped |
| `kill_prediction` | the test that would catch it, or `none found` |
| `plausibility` | why a reviewer could miss this line |
| `equivalence_risk` | the agent's own argument that the mutant is a no-op |
| `compiles_ok` | whether the mutated translation unit actually compiles, checked by the harness |

Operator classes: `deletion`, `relocation`, `reorder`, `scope`, `boundary`,
`condition`, `constant`, `state`, `error-handling`, `numeric`, `early-exit`,
`concurrency`, `serialization`. `--ops` biases the run toward some of them.

## What the harness checks itself

The agent's claims about its own patches are not evidence, so:

- **Every patch is re-checked against git.** `apply_ok` is set by the harness
  from a real `git apply --check` at the recorded commit, and is false if the
  patch touches any file other than the target or changes nothing at all.
  `patch_sha256` hashes only the `+`/`-` lines, so `duplicate_of` catches two
  mutants that are secretly the same edit.
- **Every patch is compiled.** Not the whole node, only the one translation unit it
  touches, via `tu-check` against a build dir configured in the image. The
  harness applies the patch, syntax-checks the file, reverts, and stamps
  `compiles_ok` plus the compiler's own `compile_error`. The agent runs the same
  command while it works, so a mutant that does not compile should never reach
  the manifest, and one that does is caught here rather than by a full build
  later.
- **A second agent reviews the mutants** in a fresh session that never saw the
  generation. It reads the patches (not the descriptions of them), decides
  whether each compiles, whether any reachable input actually diverges, and
  searches the tests itself. Verdicts: `sneaky` (worth running),
  `likely-killed`, `equivalent`, `invalid`. Off by default; turn it on with
  `--review`.
- **Building and testing settles it.** The review pass is still a model's
  opinion; only running the suites proves a mutant is alive.
  [`--verify`](#verifying-them-in-the-same-command) does it in a second
  container against the commit the patches were cut against, and gives a real
  `live` / `dead` verdict per mutant, with the tests that did the killing named
  and re-run once so a flake cannot pass for a kill:

  ```sh
  mutant-harness --file src/script/interpreter.cpp --verify
  ```

## Install

```sh
git clone <this repo> && cd mutant-harness
./bin/mutant-harness --build-only     # ~6 min: clones Core and the BIPs, installs a
                                      # compiler, and configures the tree for tu-check
ln -s "$PWD/bin/mutant-harness" ~/.local/bin/mutant-harness
ln -s "$PWD/bin/mutant-verify"  ~/.local/bin/mutant-verify
```

Requires `docker` and `jq`.

## Usage

```sh
mutant-harness --file src/script/interpreter.cpp
mutant-harness --file src/validation.cpp --count 20
mutant-harness --file src/net_processing.cpp --focus "headers sync"
mutant-harness --file src/policy/feerate.cpp --lines 40-120
mutant-harness --file src/txmempool.cpp --ops relocation,reorder,scope
mutant-harness --file src/pubkey.cpp --model sonnet          # cheaper
mutant-harness --file src/validation.cpp --review            # second-pass review of the mutants
mutant-harness --file src/validation.cpp --update-core       # git fetch Core master first
mutant-harness --file src/wallet/spend.cpp --repo ~/src/bitcoin   # your own clone
mutant-harness --file src/pow.cpp --verify                   # then build and test the mutants
mutant-harness --file src/pow.cpp --verify --export          # and write the live ones to out/import.json
mutant-harness --file src/validation.cpp --detach            # background
mutant-harness --file src/validation.cpp --timeout 45m
mutant-harness --shell --file src/validation.cpp             # poke around the container
mutant-harness --target secp256k1 --file src/group_impl.h --verify   # libsecp256k1
```

Full flag list: `mutant-harness --help`.

### Running the mutants

The patches apply to the commit in `repo.commit` and no other:

```sh
mutant-harness --apply results/.../out/patches/mut-003.patch --repo ~/src/bitcoin
cmake --build build && ctest --test-dir build       # did anything notice?
git -C ~/src/bitcoin checkout -- .                  # revert
```

`--apply` is a plain local `git apply` with a pre-check; it needs no container.

### Verifying them in the same command

`--verify` hands the run straight to the verifier when the agent finishes, in a
**second container**, so generation and verdicts are one command:

```sh
mutant-harness --file src/pow.cpp --verify
mutant-harness --file src/pow.cpp --verify --verify-arg --skip-functional
mutant-harness --file src/pow.cpp --verify-repo ~/src/bitcoin   # your own tree instead
```

Cold-building Core is the expensive half of verifying, so the build tree lives in
a named docker volume (`mutant-harness-build`, override with
`MUTANT_HARNESS_BUILD_VOLUME`) instead of in the container. The full build is
paid once per volume, every mutant after that is an incremental build of one
`.cpp` plus a relink - about ten seconds - and `--verify-only ... --verify-arg
--resume` picks a crashed run back up against the warm tree. Expect a few GB
per volume (4.4GB for a `RelWithDebInfo` build of `master`):

```sh
docker volume ls | grep mutant-harness      # it is there
docker volume rm mutant-harness-build       # reclaim the space
```

Only the mutants that apply *and* compile are queued - the rest would each burn
a build to prove what the manifest already says. Verdicts from `--review` are
not filtered on: an `equivalent` call is still a model's opinion, and testing it
is how you find out the model was wrong. Results land in the run's own
`out/verify/`, next to the patches they came from.

`--verify-repo <path>` verifies in a host clone of yours instead, which is what
you want for the one thing the container cannot do: testing the mutants against
*your* tree, for instance to see whether a test you just wrote kills them. That
clone is checked for being a clean git tree before the agent starts rather than
after, since the run is what you would otherwise have to throw away.

`--verify-only <run-dir>` verifies a run that already exists, with no agent and
no `--file`: use it to verify an old run, or to pick up an interrupted one
against the warm volume:

```sh
mutant-harness --verify-only results/src-pow-cpp-latest
mutant-harness --verify-only results/src-pow-cpp-latest --verify-arg --resume
```

`--verify-arg` forwards anything to the `mutant-verify` invocation in every
mode, `--docker-arg` reaches both containers, and none of them can be combined
with `--detach` or `--shell`. Two differences from a normal build to keep in mind:
the tree is configured with `-DENABLE_IPC=OFF` and `-DWITH_ZMQ=OFF`, so
functional tests needing the multiprocess binary or ZMQ do not run.

### Verifying them separately: `mutant-verify`

`bin/mutant-verify` does the whole kill/survive sweep. For each patch, in your
own clone, one at a time:

```
git apply  ->  cmake --build  ->  ctest  ->  test/functional/test_runner.py
```

The first stage that fails decides the verdict, and the tree is reverted before
the next mutant either way.

```sh
mutant-verify --repo ~/src/bitcoin --patches results/src-script-interpreter-cpp-latest/out/patches
mutant-verify --repo ~/src/bitcoin --patches .../patches --only mut-003,mut-007
mutant-verify --repo ~/src/bitcoin --patches .../patches --skip-functional   # fast first pass
mutant-verify --repo ~/src/bitcoin --patches .../patches --no-baseline       # tree is already known green
mutant-verify --repo ~/src/bitcoin --patches .../patches --resume            # after a Ctrl-C
mutant-verify --repo ~/src/bitcoin --patches .../patches \
    --functional-arg feature_taproot.py --functional-arg p2p_segwit.py
```

| status | meaning |
| --- | --- |
| `live` | built, `ctest` green, functional suite green - **nothing noticed** |
| `live-unit` | survived `ctest`; functional run was skipped |
| `dead` | a suite failed twice; `killed_by` is `ctest` or `functional` and `killed_tests` names the tests |
| `build-failed` | the mutant does not compile |
| `apply-failed` | the patch does not apply to this checkout (wrong commit?) |

A failing suite is not taken at face value. Core's tests flake, and a false
`dead` throws away the only result worth having, so `mutant-verify` reads the
names of the tests that failed out of the suite's own output and re-runs **just
those** once, not a second full suite. Only a second failure is a
kill; a test that passes the second time is recorded in `flaky` and the mutant
carries on to the next stage. A failure no test claims (a crashed runner, a
timeout) is not re-run and stands as a kill, with `killed_tests` null.

`killed_tests` is also what makes a verdict checkable by eye: a feerate mutant
killed by `feerate_tests` reads as a real kill, one killed by `p2p_permissions`
reads as something to go look at.

Results are appended as JSONL to `out/verify/results.jsonl`, with the full
output of every stage under `out/verify/logs/<id>.log`:

```sh
jq -r 'select(.status=="live") | .id' out/verify/results.jsonl

# what killed each mutant - does it make sense that it did?
jq -r 'select(.killed_tests) | "\(.id)  \(.killed_by): \(.killed_tests | join(", "))"' out/verify/results.jsonl

# tests that flaked during the run
jq -r 'select(.flaky) | "\(.id) \(.flaky | join(","))"' out/verify/results.jsonl
```

The clone must have no uncommitted tracked changes (untracked files, `build/`
included, are ignored) and must already be configured - `mutant-verify` builds,
it does not run `cmake -B`. It proves the unpatched tree is green before it
starts, because a red baseline scores every mutant as `dead`; that costs one
suite run against the N you are about to do anyway. `--no-baseline` skips it,
and `--resume` skips it by default. Full flag list: `mutant-verify --help`.

## Targets

`--target <name>` picks the tree to mutate. `core` (Bitcoin Core) is the
default; `secp256k1` is `bitcoin-core/secp256k1`. Everything that differs
between them lives in `targets/<name>.env` - repo URL, image tag, cmake flags,
extra apt packages, how headers are compile-checked, default verify args, and
the build/test commands `mutant-export` records - plus a prompt pair in
`prompts/<name>/`. Each target gets its own image (`mutant-harness-<name>`) and
verify volume (`mutant-harness-build` for core, `mutant-harness-build-<name>`
otherwise). Adding a target is one profile and two prompts.

Inside the container the tree is always at `/src/bitcoin` and the variables
keep their `BITCOIN_*` names, whatever the target; `--update-core` refreshes
whichever tree it is. `--verify-only` refuses a run made with another target.

libsecp256k1 differs from Core in ways that matter here:

- **Almost all the code is headers** included into `src/secp256k1.c`. The
  profile sets `TU_HEADER_UNITS` (`src/tests.c src/tests_exhaustive.c`), so
  `tu-check` asks the preprocessor which of those units include the header and
  syntax-checks them.
- **Some files are never compiled.** The field and scalar implementations are
  picked per platform: on x86_64 `field_10x26`, `scalar_8x32` and
  `int128_struct` are dead. Every mutant there would come back `live` without
  having been tested, so the run refuses them up front (`tu-check` exit 3).
- **No functional suite; a constant-time check instead.** Verification is
  `ctest` (unit and exhaustive tests), then `ctime_tests` under valgrind
  (`mutant-verify --ctime`, on by default for this target). A constant-time
  kill is recorded as `killed_by: "ctime"`. The image installs valgrind and
  configures with `-DSECP256K1_VALGRIND=ON`, all modules on, benchmarks off.
- **Different prompts.** The specs step reads BIP340/327/324/352, SEC1 and
  `doc/`; mutants under `#ifdef VERIFY` are ruled out; `concurrency` is replaced
  by a `constant-time` operator; the severity scale is about forgery, key
  leakage and API contracts instead of consensus and p2p.

A full libsecp256k1 build is well under a minute, so verifying is cheap next to
Core's.

## Output

```
results/src-script-interpreter-cpp-20260821T190000Z/
├── work/
│   ├── prompt.md              # the prompt template
│   ├── prompt.rendered.md     # with paths substituted
│   └── coverage.md            # the agent's map of what the tests cover
└── out/
    ├── mutants.json           # the deliverable: mutants + harness validation
    ├── mutants-reviewed.json  # the same, with a verdict on each (only with --review)
    ├── patches/mut-001.patch  # one applicable diff per mutant
    ├── report.json            # mutants.json plus the agent's long-form notes
    ├── session.txt            # readable trace of what the agent did
    ├── review.txt             # readable trace of the review pass (only with --review)
    └── session.stream.jsonl   # raw stream-json log
```

`results/<file-slug>-latest` symlinks to the most recent run for that file.

The harness stamps `target`, `repo.commit`, `repo.head`, `bips_repo.commit`, and
`harness.{model,requested_mutants,compile_checked,finished_at,duration_seconds}`
after the agent finishes, so provenance does not depend on the model getting it
right. Useful queries:

```sh
# the ones worth building (--review runs only)
jq -r '.mutants[] | select(.verdict=="sneaky") | "\(.id) \(.operator) \(.title)"' out/mutants-reviewed.json

# queue every patch that applies and compiles
jq -r '.mutants[] | select(.apply_ok and .compiles_ok != false) | .patch' out/mutants.json

# the ones that do not compile, and why
jq -r '.mutants[] | select(.compiles_ok == false) | "\(.id): \(.compile_error)"' out/mutants.json

# what the agent thinks is untested
jq -r '.coverage_map.thinly_covered[]' out/mutants.json

# mutants that break a written rule
jq -r '.mutants[] | select(.spec_violation != null) | "\(.id): \(.spec_violation)"' out/mutants.json

jq '[.mutants[] | .operator] | group_by(.) | map({op: .[0], n: length})' out/mutants.json
```

## Design notes

- **Permissions.** The agent runs with `--dangerously-skip-permissions`. That is
  safe here because the container is disposable and holds nothing but two public
  source trees and the output directory. It is *not* network isolated by default
  (Claude Code needs the API), so `--docker-arg --network=none` will not work;
  use a proxy or an egress allowlist if you care.
- **It edits the source tree.** The mutation loop is: edit the file, `git diff`
  into a patch, `git checkout --` to revert. That is why the baked-in clone
  exists. If you pass `--repo`, the agent is editing *your* clone in place -
  the harness reverts the target file before and after the run, but use a
  scratch clone rather than the one you are working in.
- **One translation unit, not a build.** Linking Core once per mutant would
  consume the entire budget, but a single `.cpp` type-checks in seconds, and
  that is all it takes to know whether an edit is valid C++. The image ships a
  *configured* tree (`cmake` configure only, no target built) and `tu-check`,
  which reads the compiler command CMake recorded for the file out of
  `compile_commands.json` and re-runs it with `-fsyntax-only`. The agent runs it
  after every edit; the harness re-runs it on each finished patch and stamps
  `compiles_ok`. The cost is a bigger image - a compiler, Boost and libevent
  headers, and a minute of configure at build time.
  If the clone is swapped (`--repo`) or refreshed (`--update-core`), the build
  dir no longer describes the tree, so the entrypoint reconfigures once into a
  throwaway dir. If that fails, or the *unpatched* file does not syntax-check on
  its own, the check turns itself off and says so rather than stamping every
  mutant broken for a fault the agent did not cause - `harness.compile_checked`
  records which way the run went, and the agent is told to reason about
  compilability instead.
- **The BIP repo** is baked in at `/src/bips`. It is what makes the guesses
  smarter than a pattern match: before choosing sites, the agent works out which
  specs the file implements and aims at the lines enforcing a written MUST, so
  each mutant has a stated consequence instead of an assumed one.
- **Bitcoin Core clone** is baked into the image at build time (shallow,
  `master`). `--update-core` refreshes it per run; `--rebuild` re-bakes it.
- **Container identity.** Runs as your host uid/gid so `results/` stays yours.
  The image tag is `mutant-harness-core:latest` and the harness verifies the
  `org.mutant-harness.kind` label before running it, so an unrelated image with
  a similar name cannot be launched by accident.
- **Auth.** `ANTHROPIC_API_KEY` if set. Otherwise the harness *copies*
  `~/.claude/.credentials.json` into the run's `work/claude-home/` and mounts
  that copy, so a token refresh inside the container cannot rotate your host
  session out from under you. The copy is a live credential: `results/` deserves
  the same care as `~/.claude`.

## Cost and runtime

A large file like `net_processing.cpp` is a long read plus a lot of grepping
through tests: expect tens of minutes on `opus`. `--model sonnet` is markedly
cheaper and still produces usable boundary and deletion mutants; `opus` is worth
it for the relocation and ordering mutants, which need the whole function held
in mind at once. The per-run cost is recorded at the end of `out/session.txt`.

`--count` above ~20 tends to produce clustered, near-duplicate mutants. Two runs
with different `--focus` values beat one big run.

## Interpreting results

A `sneaky` verdict is a hypothesis, not a measured survivor: nothing here is
compiled or executed. The manifest is a prioritised queue for the expensive
part. Build and test the `sneaky` ones first, and treat every mutant that
actually survives as a test to write, not a bug to file.
