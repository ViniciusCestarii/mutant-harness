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
mutant-harness --file src/pow.cpp --verify --export        # write live mutants to out/import.json
mutant-harness --target secp256k1 --file src/group_impl.h --verify
mutant-harness --verify-only results/src-pow-cpp-latest --verify-arg --resume
mutant-harness --apply results/.../out/patches/mut-003.patch --repo ~/src/bitcoin
```

All flags: `mutant-harness --help` and `mutant-verify --help`.

## Output

```
results/<file-slug>-<timestamp>/out/
├── mutants.json           # mutants + harness checks
├── mutants-reviewed.json  # with --review
├── patches/mut-NNN.patch
├── verify/results.jsonl   # with --verify
└── session.txt            # agent trace and cost
```

`results/<file-slug>-latest` points to the latest run.

## Checks

- **apply_ok**: patch re-checked with `git apply --check`.
- **compiles_ok**: the touched translation unit is syntax-checked.
- **--review**: a fresh agent grades each mutant `sneaky`, `likely-killed`, `equivalent` or `invalid`.
- **--verify**: builds and runs the test suites per mutant. Status is `live`, `live-unit`, `dead`, `build-failed` or `apply-failed`. Failing tests are re-run once to rule out flakes.

## Targets

`core` (default) and `secp256k1`. Each target is a profile in `targets/<name>.env` plus prompts in `prompts/<name>/`.

## Notes

- The agent runs with full permissions inside the container. The container is not network isolated, since Claude Code needs to reach the Anthropic API.
- With `--repo`, the agent edits your clone. Use a scratch clone.
- Auth uses `ANTHROPIC_API_KEY` if set. Otherwise each run copies `~/.claude/.credentials.json` into `work/claude-home/`, so a run folder contains a live login token. Don't share run folders as-is. Share `out/` only.
- The verify build tree lives in a Docker volume (`mutant-harness-build`, a few GB).
