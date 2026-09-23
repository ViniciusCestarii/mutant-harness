#!/usr/bin/env bash
# Runs inside the container for the verification phase. Configures the tree if
# this build volume is new, makes sure it is at the commit the patches were cut
# against, then hands over to mutant-verify.
#
# No credentials are mounted for this phase: it needs CPU, not an agent.
set -uo pipefail

BITCOIN_SRC="${BITCOIN_SRC:-/src/bitcoin}"
BUILD_DIR="${VERIFY_BUILD_DIR:-build}"
PATCH_DIR="${PATCH_DIR:-/out/patches}"
VERIFY_ONLY="${VERIFY_ONLY:-}"
VERIFY_COMMIT="${VERIFY_COMMIT:-}"

log() { printf '[verify] %s\n' "$*" >&2; }
die() { printf '[verify] error: %s\n' "$*" >&2; exit 1; }

command -v mutant-verify >/dev/null \
    || die "mutant-verify is not on PATH (it is mounted in, not baked)"
[[ -d "$BITCOIN_SRC/.git" ]] || die "no ${TARGET_NAME:-target} clone at $BITCOIN_SRC"
[[ -d "$PATCH_DIR" ]]        || die "no patch directory at $PATCH_DIR"

export HOME="${HOME:-/home/agent}"
mkdir -p "$HOME"
git config --global --add safe.directory "$BITCOIN_SRC" 2>/dev/null || true
git config --global user.email "harness@localhost" 2>/dev/null || true
git config --global user.name "mutant-harness" 2>/dev/null || true

# A mutant patch applies to exactly one commit. The image's clone is that commit
# unless the generation run refreshed it (--update-core), which happened in a
# different container and did not persist - so put the tree back rather than
# reporting every mutant as apply-failed.
if [[ -n "$VERIFY_COMMIT" ]]; then
    HAVE="$(git -C "$BITCOIN_SRC" rev-parse HEAD 2>/dev/null)"
    if [[ "$HAVE" != "$VERIFY_COMMIT" ]]; then
        log "tree is at ${HAVE:0:12}, patches were cut against ${VERIFY_COMMIT:0:12}; fetching"
        git -C "$BITCOIN_SRC" fetch --depth 1 origin "$VERIFY_COMMIT" 2>/dev/null \
            && git -C "$BITCOIN_SRC" checkout -q --detach FETCH_HEAD \
            || die "cannot put the tree at $VERIFY_COMMIT. Rebuild the image (--rebuild), or verify against your own clone (--verify-repo <path>)."
    fi
fi

# An interrupted earlier run can leave the tree dirty, and mutant-verify cannot
# tell a mutant's failure from a pre-existing one in a dirty tree.
git -C "$BITCOIN_SRC" checkout -- . 2>/dev/null || true

# mutant-verify builds but does not configure, so configure on a fresh volume.
# Nothing is built here: the first build is the baseline's job, and it is the
# thing this volume exists to keep.
BUILD_PATH="$BITCOIN_SRC/$BUILD_DIR"
if [[ ! -f "$BUILD_PATH/CMakeCache.txt" ]]; then
    log "configuring $BUILD_PATH (first run against this build volume)"
    cmake -B "$BUILD_PATH" -S "$BITCOIN_SRC" ${CMAKE_FLAGS:-} \
        || die "cmake configure failed"
else
    log "reusing the configured build at $BUILD_PATH"
fi

ARGS=(--repo "$BITCOIN_SRC" --patches "$PATCH_DIR" --build-dir "$BUILD_DIR")
[[ -n "$VERIFY_ONLY" ]] && ARGS+=(--only "$VERIFY_ONLY")

log "mutant-verify ${ARGS[*]} $*"
exec mutant-verify "${ARGS[@]}" "$@"
