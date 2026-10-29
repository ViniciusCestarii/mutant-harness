# mutant-harness

Runs Claude Code or Codex in a disposable Docker container to plant plausible bugs (mutants) in one file of Bitcoin Core or libsecp256k1. Each mutant ships as a `git` patch plus a manifest explaining what it breaks and why the tests might miss it.

Tools like `bcore-mutation` apply fixed single-line changes (`<` to `<=`, delete a statement). This harness instead reads the file, the BIPs it implements and its tests, then plants a few targeted mutants where impact is high and coverage is thin. It can make changes a line-level tool cannot: move a statement past its guard, hoist a block out of a branch, reorder validations or drop a `return false` in a loop. The two approaches find different gaps and make different trade-offs, so run both.

## Install

Requires `docker` and `jq`.

Claude is the default agent; no environment variable is required to select it.
To use GPT via Codex, run `export AGENT=codex` before building the image and keep
it exported for subsequent runs. Set it again if you open a new terminal.
The image installs only the selected agent.

```sh
git clone https://github.com/ViniciusCestarii/mutant-harness.git && cd mutant-harness
# For Codex only (skip this line to use the default, Claude):
# export AGENT=codex
./bin/mutant-harness --build-only
ln -s "$PWD/bin/mutant-harness" ~/.local/bin/mutant-harness
ln -s "$PWD/bin/mutant-verify"  ~/.local/bin/mutant-verify
```

`--build-only` does not require credentials. The harness also builds the image
automatically when needed, including when you switch `AGENT`.

## Usage

Before generating mutants, provide the API key for your selected agent.
For Claude:

```sh
export ANTHROPIC_API_KEY="your-anthropic-api-key"
```

For Codex:

```sh
export OPENAI_API_KEY="your-openai-api-key"
```

Alternatively, reuse an existing local CLI login. Without an API key, the
harness copies Claude's login cache or Codex's `auth.json` into the container.
Codex's cache is read from `CODEX_HOME` (default: `~/.codex`) and must be file
based; OS keyring credentials are not copied. With `OPENAI_API_KEY`, the harness
runs `codex login --with-api-key` inside the container before starting Codex.
If neither a key nor a login cache is available, the run stops with an error.

```sh
mutant-harness --file src/script/interpreter.cpp
mutant-harness --file src/net_processing.cpp --count 20 --focus "compact blocks"
mutant-harness --file src/pow.cpp --verify                 # build and test the mutants
mutant-harness --file src/pow.cpp --verify --export        # write live mutants to out/import.json
mutant-harness --target secp256k1 --file src/group_impl.h --verify
mutant-harness --file src/validation.cpp --pr 12345        # mutate only the lines a PR adds
mutant-harness --pr 12345                                  # ...in every source file it touches
mutant-harness --file src/net_processing.cpp --structural  # skip what a line-level tool would make
mutant-harness --verify-only results/src-pow-cpp-latest --verify-arg --resume
mutant-harness --apply results/.../out/patches/mut-003.patch --repo ~/src/bitcoin
```

All flags: `mutant-harness --help` and `mutant-verify --help`.

Claude is the default agent, with `opus` as its default model.
Codex's default model is `gpt-6-astra`.
`--model` overrides either default, and `--review-model` defaults to the
generation model. The selected agent runs both generation and review, including
`--review-only`. `--fallback-model` is supported only by Claude.

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
- **line_level**: the patch is a one-token swap or a single-line deletion, which a line-level tool also makes. With `--structural` the agent is told to avoid these and they are not verified.
- **--review**: a fresh agent grades each mutant `good`, `noise` or `invalid` on whether it is worth reporting; mutants a previous `--verify` killed are marked `dead` without review. With `--verify`, the review runs after verification.
- **--verify**: builds and runs the test suites per mutant. Status is `live`, `live-unit`, `dead`, `build-failed` or `apply-failed`. Failing tests are re-run once to rule out flakes.

## Targets

`core` (default) and `secp256k1`. Each target is a profile in `targets/<name>.env` plus prompts in `prompts/<name>/`.

## Notes

- The agent runs with full permissions inside the container. The container is not network isolated, since the agent needs to reach its provider's API.
- With `--repo`, the agent edits your clone. Use a scratch clone.
- Claude auth uses `ANTHROPIC_API_KEY` if set. Otherwise each run copies `~/.claude/.credentials.json` into `work/claude-home/`. Codex login caches are copied into `work/codex-home/`. Run folders using login caches contain live tokens. Don't share run folders as-is. Share `out/` only.
- Codex logs token usage rather than a dollar cost. Its `cost_usd` values in `summary.json` are `null`, including totals containing an unknown cost. Token usage is preserved in the session/review logs.
- The verify build tree lives in a Docker volume (`mutant-harness-build`, a few GB).
