#!/usr/bin/env bash
#
# Apply the GL.iNet patches in patches/ to a Tailscale source tree.
#
# Why this exists: the build resolves its Tailscale tag from releases/latest, so the
# source moves underneath the patches. A bare `patch -p1 < file` then fails in the two
# worst possible ways -- it kills the build when a patch has merely been upstreamed,
# and it cannot tell that case apart from a patch that no longer applies at all.
# (That is exactly what happened when tailscale v1.100.0 absorbed the nftables fwmark
# endianness fix: every matrix leg died on "Reversed (or previously applied) patch
# detected!".)
#
# So: patches that tailscale has since adopted are skipped with a warning, patches that
# genuinely no longer fit abort the build with the rejects printed, and afterwards the
# end state is asserted in the source itself -- a skipped or misplaced hunk can never
# quietly produce a binary without the GL.iNet behaviour.
#
# Usage: apply-tailscale-patches.sh [--patch-dir DIR] [--source-dir DIR] [--check-only]

set -euo pipefail

# Tailscale release the patches were last rebased against and built with. Bump this
# together with the patches. A mismatch only warns -- the floating "latest" resolution
# is supposed to keep flowing; the end-state assertions are the hard gate.
PATCHES_TESTED_TAG="v1.102.1"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PATCH_DIR="$SCRIPT_DIR/../patches"
SOURCE_DIR="."
CHECK_ONLY=false

note() { printf '%s\n' "$*"; }

warn() {
    printf 'WARNING: %s\n' "$*" >&2
    if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::warning::%s\n' "$*"; fi
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf -- '- :warning: %s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
    fi
    return 0
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::error::%s\n' "$*"; fi
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --patch-dir)  PATCH_DIR=$2; shift 2 ;;
        --source-dir) SOURCE_DIR=$2; shift 2 ;;
        --check-only) CHECK_ONLY=true; shift ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -d "$PATCH_DIR" ]  || die "patch directory not found: $PATCH_DIR"
[ -d "$SOURCE_DIR" ] || die "source directory not found: $SOURCE_DIR"

PATCH_DIR=$(CDPATH='' cd -- "$PATCH_DIR" && pwd)
cd "$SOURCE_DIR"

[ -f util/linuxfw/linuxfw.go ] || die \
    "$SOURCE_DIR does not look like a Tailscale checkout (util/linuxfw/linuxfw.go is missing)"

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

# Deliberately non-recursive and explicitly numbered: patches/verify/ holds a Go test,
# not a patch, and must never be swept in here.
apply_all() {
    local found=false patch_file
    for patch_file in "$PATCH_DIR"/[0-9][0-9][0-9][0-9]-*.patch; do
        [ -e "$patch_file" ] || continue
        found=true
        apply_one "$patch_file"
    done

    if [ "$found" = false ]; then
        warn "no patches found in $PATCH_DIR -- relying entirely on the end-state assertions"
    fi
}

apply_one() {
    local patch_file=$1 name out rc
    name=$(basename "$patch_file")

    set +e
    out=$(patch -p1 --forward --batch --dry-run -i "$patch_file" 2>&1)
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        patch -p1 --forward --batch --no-backup-if-mismatch -i "$patch_file" >/dev/null
        note "applied:  $name"
        return 0
    fi

    # Tolerated: tailscale has adopted the change itself. Requires the reversal notice
    # *and* not a single failed hunk -- a mix of the two means the patch is half-stale
    # and must be looked at, not skipped.
    if printf '%s\n' "$out" | grep -q 'Reversed (or previously applied) patch detected' &&
        ! printf '%s\n' "$out" | grep -q 'FAILED'; then
        warn "already applied upstream, skipping: $name (retire it -- see patches/README.md)"
        return 0
    fi

    printf '%s\n' "$out" >&2
    # Materialise the rejects so the CI log says which hunk drifted and where. The tree
    # is discarded either way, we are on our way out.
    patch -p1 --forward --batch -i "$patch_file" >/dev/null 2>&1 || true
    find . -name '*.rej' -print -exec cat {} + >&2 || true
    die "$name no longer applies to this Tailscale source -- rebase it (see patches/README.md)"
}

# ---------------------------------------------------------------------------
# End-state assertions
#
# These run on every matrix leg and are pure text checks, so they are cheap. The
# authoritative structural check is patches/verify/gl_invariants_test.go, which the
# workflow runs once via `go test`.
# ---------------------------------------------------------------------------

assert_end_state() {
    local lfw="util/linuxfw/linuxfw.go"
    local nfr="util/linuxfw/nftables_runner.go"
    local body last_ct last_cmp meta_line ct_loads

    # Retired patch 0001: tailscale v1.100.0 fixed the fwmark byte order itself
    # (tailscale/tailscale#11803). The hardcoded big-endian literals must not return.
    if grep -q '0xff, 0x00, 0xff, 0xff' "$lfw"; then
        die "$lfw still contains the big-endian fwmark literals -- tailscale reverted the \
#11803 fix, so patches/0001-fix-nftables-fwmark-endianness.patch has to come back"
    fi
    grep -q 'binary.NativeEndian' "$lfw" || die \
        "$lfw does not use binary.NativeEndian for the fwmark bytes -- see tailscale/tailscale#11803"

    # patches/0002: makeConnmarkRestoreExprs must load the ct mark twice -- once masked
    # for the non-zero guard, once unmasked right before the meta-mark assignment.
    body=$(awk '/^func makeConnmarkRestoreExprs\(\)/{f=1} f{print} f&&/^}$/{exit}' "$nfr")
    [ -n "$body" ] || die "could not locate makeConnmarkRestoreExprs() in $nfr"

    ct_loads=$(printf '%s\n' "$body" | grep -c 'expr\.CtKeyMARK' || true)
    [ "$ct_loads" -eq 2 ] || die \
        "makeConnmarkRestoreExprs() loads the ct mark $ct_loads time(s), want 2 -- \
patches/0002-nft-connmark-restore-gl-coexist.patch did not take effect"

    last_ct=$(printf  '%s\n' "$body" | grep -n 'expr\.CtKeyMARK' | tail -1 | cut -d: -f1)
    last_cmp=$(printf '%s\n' "$body" | grep -n '&expr\.Cmp{'     | tail -1 | cut -d: -f1)
    meta_line=$(printf '%s\n' "$body" | grep -n '&expr\.Meta{'    | tail -1 | cut -d: -f1)
    [ -n "$last_cmp" ] && [ -n "$meta_line" ] || die \
        "makeConnmarkRestoreExprs() no longer has the expected Cmp/Meta shape -- rebase patches/0002"
    if [ "$last_ct" -lt "$last_cmp" ] || [ "$last_ct" -gt "$meta_line" ]; then
        die "the unmasked ct-mark reload is not between the non-zero guard and the \
meta-mark assignment -- patches/0002 applied in the wrong place"
    fi

    note "end state OK: native-endian fwmark bytes, connmark restore copies the full ct mark"
}

check_drift() {
    local tag=${TAILSCALE_TAG:-}
    [ -n "$tag" ] || return 0
    [ "$tag" = "$PATCHES_TESTED_TAG" ] && return 0
    warn "building tailscale $tag, but patches/ were last rebased against $PATCHES_TESTED_TAG \
-- if this build is green the patches still fit; bump PATCHES_TESTED_TAG in $(basename "$0")"
}

if [ "$CHECK_ONLY" = false ]; then
    apply_all
fi
assert_end_state
check_drift
