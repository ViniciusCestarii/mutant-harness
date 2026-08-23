#!/usr/bin/env bash
# Runs inside the container. Prepares the workspace, invokes Claude Code
# headless to plant mutants, mechanically checks every patch it produced, and
# guarantees a mutants JSON lands in /out.
set -uo pipefail

TARGET_FILE="${TARGET_FILE:?TARGET_FILE not set}"
BITCOIN_SRC="${BITCOIN_SRC:-/src/bitcoin}"
BIPS_SRC="${BIPS_SRC:-/src/bips}"
OUT_DIR="${OUT_DIR:-/out}"
# The agent writes one full report plus one patch file per mutant. We validate
# the patches against git and fold the results back into mutants.json, which is
# the file a human opens.
REPORT_FILE="${REPORT_FILE:-$OUT_DIR/report.json}"
MANIFEST_FILE="${MANIFEST_FILE:-$OUT_DIR/mutants.json}"
REVIEWED_FILE="${REVIEWED_FILE:-$OUT_DIR/mutants-reviewed.json}"
PATCH_DIR="${PATCH_DIR:-$OUT_DIR/patches}"
PROMPT_TEMPLATE="${PROMPT_TEMPLATE:-/work/prompt.md}"
REVIEW_PROMPT_TEMPLATE="${REVIEW_PROMPT_TEMPLATE:-/work/review.md}"
REVIEW="${REVIEW:-1}"
MODEL="${MODEL:-opus}"
REVIEW_MODEL="${REVIEW_MODEL:-$MODEL}"
FALLBACK_MODEL="${FALLBACK_MODEL:-}"
MUTANT_COUNT="${MUTANT_COUNT:-12}"
FOCUS="${FOCUS:-}"
LINE_RANGE="${LINE_RANGE:-}"
OPS="${OPS:-}"
UPDATE_CORE="${UPDATE_CORE:-0}"
UPDATE_BIPS="${UPDATE_BIPS:-0}"

log() { printf '[harness] %s\n' "$*" >&2; }
die() { printf '[harness] error: %s\n' "$*" >&2; exit 1; }

[[ -r "$PROMPT_TEMPLATE" ]] || die "prompt not readable at $PROMPT_TEMPLATE"
[[ -d "$BITCOIN_SRC/.git" ]] || die "no Bitcoin Core clone at $BITCOIN_SRC"
[[ -d "$BIPS_SRC/.git" ]] || die "no bitcoin/bips clone at $BIPS_SRC"

mkdir -p "$OUT_DIR" "$PATCH_DIR" /work
export HOME="${HOME:-/home/agent}"
mkdir -p "$HOME"
git config --global --add safe.directory "$BITCOIN_SRC" 2>/dev/null || true
git config --global --add safe.directory "$BIPS_SRC" 2>/dev/null || true
git config --global user.email "harness@localhost" 2>/dev/null || true
git config --global user.name "mutant-harness" 2>/dev/null || true

if [[ "$UPDATE_CORE" == "1" ]]; then
    log "refreshing Bitcoin Core master..."
    git -C "$BITCOIN_SRC" fetch --depth 1 origin master \
        && git -C "$BITCOIN_SRC" reset --hard FETCH_HEAD \
        || log "warning: refresh failed, using the baked-in clone"
fi

if [[ "$UPDATE_BIPS" == "1" ]]; then
    log "refreshing bitcoin/bips master..."
    git -C "$BIPS_SRC" fetch --depth 1 origin master \
        && git -C "$BIPS_SRC" reset --hard FETCH_HEAD \
        || log "warning: refresh failed, using the baked-in bips clone"
fi

CORE_COMMIT="$(git -C "$BITCOIN_SRC" rev-parse HEAD)"
CORE_DESC="$(git -C "$BITCOIN_SRC" log -1 --format='%cI %s')"
BIPS_COMMIT="$(git -C "$BIPS_SRC" rev-parse HEAD)"
BIPS_DESC="$(git -C "$BIPS_SRC" log -1 --format='%cI %s')"
log "bitcoin core @ $CORE_COMMIT"
log "            $CORE_DESC"
log "bitcoin bips @ $BIPS_COMMIT"

# --------------------------------------------------------------- target ----
TARGET_PATH="$BITCOIN_SRC/$TARGET_FILE"
[[ -f "$TARGET_PATH" ]] || die "no such file in the Core tree: $TARGET_FILE"
TARGET_LINES="$(wc -l < "$TARGET_PATH")"
log "target: $TARGET_FILE ($TARGET_LINES lines)"

# A dirty target file would make every `git diff` the agent takes include
# somebody else's edits, so start from a known-clean copy of it.
if ! git -C "$BITCOIN_SRC" diff --quiet -- "$TARGET_FILE"; then
    log "warning: $TARGET_FILE was dirty; reverting it before the run"
    git -C "$BITCOIN_SRC" checkout -- "$TARGET_FILE" || die "cannot revert $TARGET_FILE"
fi

# Human-readable framing for the prompt, so an unset flag reads as a sentence
# rather than as an empty placeholder.
if [[ -n "$LINE_RANGE" ]]; then
    RANGE_TEXT="Restrict every mutation to lines $LINE_RANGE of the file. Mutants outside that range will be discarded."
else
    RANGE_TEXT="The whole file is in scope."
fi
if [[ -n "$FOCUS" ]]; then
    FOCUS_TEXT="Concentrate on: $FOCUS. Spend your budget there; only spill outside it if that area cannot absorb $MUTANT_COUNT distinct mutants."
else
    FOCUS_TEXT="No particular area was named, so spread the mutants across the interesting logic of the file rather than clustering them in one function."
fi
if [[ -n "$OPS" ]]; then
    OPS_TEXT="Prefer these operator classes: $OPS. Use others only where those do not fit."
else
    OPS_TEXT="All operator classes below are available; pick per site whichever produces the most plausible bug."
fi

# ------------------------------------------------------------- helpers ----
export TARGET_FILE TARGET_PATH TARGET_LINES BITCOIN_SRC BIPS_SRC OUT_DIR \
       REPORT_FILE PATCH_DIR MUTANT_COUNT RANGE_TEXT FOCUS_TEXT OPS_TEXT

# Materialise a prompt with the run's paths substituted in.
render_prompt() {
    python3 - "$1" "$2" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
keys = ("TARGET_FILE", "TARGET_PATH", "TARGET_LINES", "BITCOIN_SRC", "BIPS_SRC",
        "OUT_DIR", "REPORT_FILE", "PATCH_DIR", "MUTANT_COUNT", "RANGE_TEXT",
        "FOCUS_TEXT", "OPS_TEXT", "IN_MUTANTS", "OUT_REVIEWED")
# Longest first so a shorter name never eats the prefix of a longer one.
for k in sorted(keys, key=len, reverse=True):
    v = os.environ.get(k)
    if v:
        text = text.replace("$" + k, v)
open(dst, "w", encoding="utf-8").write(text)
PY
    [[ -s "$2" ]] || die "failed to render prompt $1"
}

# run_claude <prompt> <stream_log> <model> <add-dir>...
run_claude() {
    local prompt="$1" stream="$2" model="$3"; shift 3
    local args=(-p --model "$model" --dangerously-skip-permissions
                --output-format stream-json --verbose)
    local d; for d in "$@"; do args+=(--add-dir "$d"); done
    [[ -n "$FALLBACK_MODEL" ]] && args+=(--fallback-model "$FALLBACK_MODEL")
    claude "${args[@]}" < "$prompt" > "$stream"
}

# Human-readable trace of what an agent did, alongside the raw stream.
make_trace() {
    [[ -s "$1" ]] || return 0
    jq -r '
      if .type == "assistant" then
        (.message.content[]? |
          if .type == "text" then "\n=== assistant ===\n" + .text
          elif .type == "tool_use" then "--- tool: " + .name + " " + ((.input | tostring)[0:400])
          else empty end)
      elif .type == "result" then
        "\n=== result ===\nsubtype=" + (.subtype // "?") +
        " turns=" + ((.num_turns // 0) | tostring) +
        " cost_usd=" + ((.total_cost_usd // 0) | tostring)
      else empty end
    ' "$1" > "$2" 2>/dev/null || true
}

# An agent is told to write its JSON file itself. If it only spoke the JSON, or
# wrapped it in a fence, recover it from the final result message.
recover_json() {
    local stream="$1" dest="$2"
    [[ -s "$dest" ]] && return 0
    log "no file at $dest; attempting recovery from final message"
    jq -r 'select(.type == "result") | .result // empty' "$stream" 2>/dev/null \
        | sed -e 's/^```json$//' -e 's/^```$//' \
        | python3 -c '
import sys, json, re
raw = sys.stdin.read()
m = re.search(r"\{.*\}", raw, re.S)
if m:
    try:
        json.dump(json.loads(m.group(0)), open(sys.argv[1], "w"), indent=2)
    except Exception:
        pass
' "$dest" 2>/dev/null || true
}

# ------------------------------------------------------------ validate ----
# The agent's own claims about its patches are not evidence. Every patch is
# re-checked against git here: does it apply to this exact commit, does it touch
# only the target file, does it change anything at all, and is it a duplicate of
# another mutant? Whatever the agent wrote in those fields is overwritten.
validate_patches() {
    python3 - "$REPORT_FILE" <<'PY'
import hashlib, json, os, subprocess, sys

report_path = sys.argv[1]
src         = os.environ["BITCOIN_SRC"]
patch_dir   = os.environ["PATCH_DIR"]
target      = os.environ["TARGET_FILE"]

with open(report_path, encoding="utf-8") as fh:
    report = json.load(fh)

mutants = report.get("mutants") or []
seen = {}
claimed = set()

def git(*args):
    return subprocess.run(["git", "-C", src, *args],
                          capture_output=True, text=True)

for m in mutants:
    mid = str(m.get("id") or "").strip()
    patch = os.path.join(patch_dir, f"{mid}.patch")
    m["patch"] = f"patches/{mid}.patch"
    claimed.add(f"{mid}.patch")

    if not mid or not os.path.isfile(patch):
        m.update(apply_ok=False, apply_error=f"no patch file at patches/{mid}.patch",
                 files_touched=[], lines_added=0, lines_removed=0)
        continue
    if os.path.getsize(patch) == 0:
        m.update(apply_ok=False, apply_error="patch file is empty",
                 files_touched=[], lines_added=0, lines_removed=0)
        continue

    check = git("apply", "--check", "--whitespace=nowarn", patch)
    m["apply_ok"] = check.returncode == 0
    if check.returncode != 0:
        m["apply_error"] = (check.stderr or check.stdout).strip()[:400]

    stat = git("apply", "--numstat", "--whitespace=nowarn", patch)
    files, added, removed = [], 0, 0
    if stat.returncode == 0:
        for line in stat.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) == 3:
                a, r, f = parts
                files.append(f)
                added   += int(a) if a.isdigit() else 0
                removed += int(r) if r.isdigit() else 0
    m["files_touched"] = files
    m["lines_added"]   = added
    m["lines_removed"] = removed

    if files and files != [target]:
        m["apply_ok"] = False
        m["apply_error"] = f"touches {files}, expected only {target}"
    if m.get("apply_ok") and added == 0 and removed == 0:
        m["apply_ok"] = False
        m["apply_error"] = "patch changes nothing"

    # Two mutants with byte-identical bodies are one mutant. Hash only the +/-
    # lines so differing hunk headers do not hide a duplicate.
    with open(patch, encoding="utf-8", errors="replace") as fh:
        body = "".join(l for l in fh
                       if (l.startswith(("+", "-")) and not l.startswith(("+++", "---"))))
    digest = hashlib.sha256(body.encode()).hexdigest()
    m["patch_sha256"] = digest
    if digest in seen:
        m["duplicate_of"] = seen[digest]
    else:
        seen[digest] = mid

# Patches the agent wrote but never listed are invisible to every consumer of
# the manifest, so surface them instead of letting them rot in the directory.
orphans = sorted(f for f in os.listdir(patch_dir)
                 if f.endswith(".patch") and f not in claimed)
if orphans:
    report["orphan_patches"] = orphans

report["mutants"] = mutants
with open(report_path, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2)

ok  = sum(1 for m in mutants if m.get("apply_ok"))
dup = sum(1 for m in mutants if m.get("duplicate_of"))
print(f"{len(mutants)} {ok} {dup} {len(orphans)}")
PY
}

# -------------------------------------------------------------- review ----
# Second pass: a *fresh* Claude session that never saw the generation. It gets
# the manifest, the patches, the file and the BIPs - and nothing from the first
# agent's context, so it cannot inherit its reasoning. Staged in its own
# directory so it cannot read report.json either.
run_review_pass() {
    local count="$1"

    [[ "$REVIEW" == "1" ]] || { log "review pass disabled (REVIEW=0)"; return 0; }
    [[ -r "$REVIEW_PROMPT_TEMPLATE" ]] || {
        log "warning: no review prompt at $REVIEW_PROMPT_TEMPLATE, skipping"; return 0; }
    if [[ "$count" == "0" ]]; then
        jq '.mutants = [] | .review = {status: "skipped-no-mutants"}' \
            "$MANIFEST_FILE" > "$REVIEWED_FILE"
        log "no mutants to review; wrote empty $REVIEWED_FILE"
        return 0
    fi

    local dir=/work/review
    rm -rf "$dir"; mkdir -p "$dir/patches"
    cp "$MANIFEST_FILE" "$dir/mutants.json"
    cp "$PATCH_DIR"/*.patch "$dir/patches/" 2>/dev/null || true

    export IN_MUTANTS="$dir/mutants.json"
    export OUT_REVIEWED="$dir/mutants-reviewed.json"
    PATCH_DIR="$dir/patches" render_prompt "$REVIEW_PROMPT_TEMPLATE" "$dir/prompt.md"

    local stream="$OUT_DIR/review.stream.jsonl"
    log "reviewing $count mutants in a fresh session (model=$REVIEW_MODEL) ..."
    local start; start=$(date +%s)
    run_claude "$dir/prompt.md" "$stream" "$REVIEW_MODEL" "$dir" "$BIPS_SRC"
    local rc=$? elapsed=$(( $(date +%s) - start ))
    log "reviewer exited rc=$rc after ${elapsed}s"

    make_trace "$stream" "$OUT_DIR/review.txt"
    recover_json "$stream" "$OUT_REVIEWED"

    if [[ ! -s "$OUT_REVIEWED" ]] || ! jq empty "$OUT_REVIEWED" 2>/dev/null; then
        log "warning: review pass produced no valid JSON (see $stream)"
        log "         mutants.json is still the unreviewed generator output"
        return 0
    fi

    # The reviewer may only annotate; ids it invented or dropped are a bug, so
    # report the drift rather than trusting the count.
    local before after
    before=$(jq -r '[.mutants[].id] | sort | @csv' "$MANIFEST_FILE")
    after=$(jq -r '[.mutants[]?.id] | sort | @csv' "$OUT_REVIEWED")
    [[ "$before" == "$after" ]] || log "warning: reviewer changed the mutant set"

    jq --arg model "$REVIEW_MODEL" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --argjson elapsed "$elapsed" \
       '. + {review: {model: $model, finished_at: $ts,
                      duration_seconds: $elapsed,
                      sneaky:        [.mutants[]? | select(.verdict == "sneaky")]        | length,
                      likely_killed: [.mutants[]? | select(.verdict == "likely-killed")] | length,
                      equivalent:    [.mutants[]? | select(.verdict == "equivalent")]    | length,
                      invalid:       [.mutants[]? | select(.verdict == "invalid")]       | length}}' \
       "$OUT_REVIEWED" > "$REVIEWED_FILE"

    log "wrote $REVIEWED_FILE ($(jq -r '.review
          | "\(.sneaky) sneaky, \(.likely_killed) likely-killed, \(.equivalent) equivalent, \(.invalid) invalid"' \
          "$REVIEWED_FILE"))"
}

# ------------------------------------------------------------- mutate ----
PROMPT_RENDERED=/work/prompt.rendered.md
render_prompt "$PROMPT_TEMPLATE" "$PROMPT_RENDERED"

rm -f "$REPORT_FILE" "$MANIFEST_FILE" "$REVIEWED_FILE"
rm -f "$PATCH_DIR"/*.patch 2>/dev/null

STREAM_LOG="$OUT_DIR/session.stream.jsonl"
cd "$BITCOIN_SRC" || die "cannot enter $BITCOIN_SRC"

log "starting claude (model=$MODEL) ..."
START=$(date +%s)
run_claude "$PROMPT_RENDERED" "$STREAM_LOG" "$MODEL" "$OUT_DIR" /work "$BIPS_SRC"
CLAUDE_RC=$?
ELAPSED=$(( $(date +%s) - START ))
log "claude exited rc=$CLAUDE_RC after ${ELAPSED}s"

make_trace "$STREAM_LOG" "$OUT_DIR/session.txt"
recover_json "$STREAM_LOG" "$REPORT_FILE"

# The agent is told to revert after each mutant, but a crash mid-mutant would
# leave the tree dirty and every later `git apply --check` would be meaningless.
if ! git -C "$BITCOIN_SRC" diff --quiet -- "$TARGET_FILE"; then
    log "warning: $TARGET_FILE left modified by the agent; reverting before validation"
    git -C "$BITCOIN_SRC" checkout -- "$TARGET_FILE"
fi

if [[ -s "$REPORT_FILE" ]] && jq empty "$REPORT_FILE" 2>/dev/null; then
    # Stamp provenance the agent cannot be trusted to get right.
    TMP=$(mktemp /work/report.XXXXXX.json)
    jq --arg file "$TARGET_FILE" \
       --arg lines "$LINE_RANGE" \
       --arg focus "$FOCUS" \
       --argjson filelines "$TARGET_LINES" \
       --arg commit "$CORE_COMMIT" \
       --arg desc "$CORE_DESC" \
       --arg bipscommit "$BIPS_COMMIT" \
       --arg bipsdesc "$BIPS_DESC" \
       --arg model "$MODEL" \
       --argjson requested "$MUTANT_COUNT" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --argjson elapsed "$ELAPSED" \
       '. + {target: ((.target // {}) + {file: $file, file_lines: $filelines,
                                         lines: (if $lines == "" then null else $lines end),
                                         focus: (if $focus == "" then null else $focus end)}),
             repo: ((.repo // {}) + {commit: $commit, head: $desc}),
             bips_repo: {commit: $bipscommit, head: $bipsdesc},
             harness: {model: $model, requested_mutants: $requested,
                       finished_at: $ts, duration_seconds: $elapsed}}' \
       "$REPORT_FILE" > "$TMP" && mv "$TMP" "$REPORT_FILE"

    STATS="$(validate_patches)"
    if [[ -n "$STATS" ]]; then
        read -r N_TOTAL N_OK N_DUP N_ORPHAN <<< "$STATS"
        log "patches: $N_TOTAL claimed, $N_OK apply cleanly, $N_DUP duplicates, $N_ORPHAN orphaned"
    else
        log "warning: patch validation failed; apply_ok fields are unreliable"
    fi

    # mutants.json is the deliverable; report.json keeps everything the agent
    # wrote, including the long-form reading notes a manifest reader does not
    # need in front of the mutant list.
    jq 'del(.notes) | .mutants //= []' "$REPORT_FILE" > "$MANIFEST_FILE"

    COUNT=$(jq '(.mutants // []) | length' "$MANIFEST_FILE")
    log "wrote $MANIFEST_FILE ($COUNT mutants)"
    log "wrote $REPORT_FILE (full report)"

    run_review_pass "$COUNT"
    exit 0
fi

log "no valid report JSON produced (see $STREAM_LOG)"
exit "${CLAUDE_RC:-1}"
