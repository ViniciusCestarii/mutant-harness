# mutant-harness

Runs Claude Code in a disposable Docker container to plant plausible bugs (mutants) in one file of Bitcoin Core or libsecp256k1. Each mutant ships as a `git` patch plus a manifest explaining what it breaks and why the tests might miss it.

Tools like `bcore-mutation` apply fixed single-line changes (`<` to `<=`, delete a statement). This harness instead reads the file, the BIPs it implements and its tests, then plants a few targeted mutants where impact is high and coverage is thin. It can make changes a line-level tool cannot: move a statement past its guard, hoist a block out of a branch, reorder validations or drop a `return false` in a loop. The two approaches find different gaps and make different trade-offs, so run both.

## Install

Requires `docker` and `jq`.

```sh
git clone https://github.com/ViniciusCestarii/mutant-harness.git && cd mutant-harness
./bin/mutant-harness --build-only
ln -s "$PWD/bin/mutant-harness" ~/.local/bin/mutant-harness
ln -s "$PWD/bin/mutant-verify"  ~/.local/bin/mutant-verify
```

## Usage

```sh
mutant-harness --file src/script/interpreter.cpp
mutant-harness --file src/net_processing.cpp --count 20 --focus "compact blocks"
mutant-harness --file src/pow.cpp --verify                 # build and test the mutants
mutant-harness --file src/pow.cpp --verify --export        # write live mutants to debug/import.json
mutant-harness --target secp256k1 --file src/group_impl.h --verify
mutant-harness --file src/validation.cpp --pr 12345        # mutate only the lines a PR adds
mutant-harness --pr 12345                                  # ...in every source file it touches
mutant-harness --file src/net_processing.cpp --structural  # skip what a line-level tool would make
mutant-harness --verify-only results/src-pow-cpp-latest --verify-arg --resume
mutant-harness --apply results/.../debug/patches/mut-003.patch --repo ~/src/bitcoin
```

All flags: `mutant-harness --help` and `mutant-verify --help`.

## Output

```
results/<file-slug>-<timestamp>/
├── mutants-verified-reviewed.json  # the result: id, title and full patch path of each good mutant
└── debug/                          # everything else
    ├── mutants.json                # every mutant + harness checks
    ├── mutants-reviewed.json       # with --review
    ├── patches/mut-NNN.patch
    ├── verify/results.jsonl        # with --verify
    ├── summary.json                # wall time, cost, counts
    └── session.txt                 # agent trace and cost
```

The result file is named after what vetted its mutants: `mutants-verified-reviewed.json` (survived the tests and the review called them `good`), `mutants-verified.json`, `mutants-reviewed.json`, or `mutants.json` (every mutant that applies and compiles). A `--pr` run writes one for all its files, in `results/pr-<n>-<timestamp>/`.

`results/<file-slug>-latest` points to the latest run.

## Checks

- **apply_ok**: patch re-checked with `git apply --check`.
- **compiles_ok**: the touched translation unit is syntax-checked.
- **line_level**: the patch is a one-token swap or a single-line deletion, which a line-level tool also makes. With `--structural` the agent is told to avoid these and they are not verified.
- **--review**: a fresh agent grades each mutant `good`, `noise` or `invalid` on whether it is worth reporting; mutants a previous `--verify` killed are marked `dead` without review. With `--verify`, the review runs after verification.
- **--verify**: builds and runs the test suites per mutant. Status is `live`, `live-unit`, `dead`, `build-failed` or `apply-failed`. Failing tests are re-run once to rule out flakes.

## Targets

`core` (default) and `secp256k1`. Each target is a profile in `targets/<name>.env` plus prompts in `prompts/<name>/`.

## Notes

- The agent runs with full permissions inside the container. The container is not network isolated, since Claude Code needs to reach the Anthropic API.
- With `--repo`, the agent edits your clone. Use a scratch clone.
- Auth uses `ANTHROPIC_API_KEY` if set. Otherwise each run copies `~/.claude/.credentials.json` into `work/claude-home/`, so a run folder contains a live login token. Don't share run folders as-is. Share the result file and `debug/` only.
- The verify build tree lives in a Docker volume (`mutant-harness-build`, a few GB).
