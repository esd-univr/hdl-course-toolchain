#!/usr/bin/env bash
# Integration tests for prepare-release.sh / publish-release.sh / release_lib.sh.
# Never touches the real origin or a real registry: docker and gh are PATH stubs
# that log their arguments and answer from files in a scratch dir; origin is a
# local bare repo.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; [ $# -gt 1 ] && printf '    got: %s\n' "$2"; }
has()   { case "$2" in *"$3"*) ok ;; *) bad "$1 — expected to contain: $3" "$2" ;; esac; }
eq()    { [ "$2" = "$3" ] && ok || bad "$1 — expected '$3'" "$2"; }
neq0()  { [ "$2" != "0" ] && ok || bad "$1 — expected non-zero exit" "$2"; }

cd "$ROOT" || exit 1

# shellcheck source=scripts/release_lib.sh
. scripts/release_lib.sh

echo "== release_lib.sh tests =="

# --- release_inputs_fingerprint ------------------------------------------
fp1="$(release_inputs_fingerprint)"
eq "release_inputs_fingerprint is 64 hex" "$(printf '%s' "$fp1" | wc -c | tr -d ' ')" "64"
case "$fp1" in
    *[!0-9a-f]*) bad "release_inputs_fingerprint is lowercase hex" "$fp1" ;;
    *) ok ;;
esac

# mutating a release input changes the fingerprint
tmp="$(mktemp)"; cp VERSION "$tmp"
printf 'x\n' >> VERSION
fp2="$(release_inputs_fingerprint)"
[ "$fp1" != "$fp2" ] && ok || bad "fingerprint should change when VERSION changes"
cp "$tmp" VERSION; rm -f "$tmp"

# restored input restores the fingerprint
eq "fingerprint is stable once VERSION is restored" "$(release_inputs_fingerprint)" "$fp1"

# --- build_inputs_fingerprint (delegates to artifact-status.sh) ---------
bfp="$(build_inputs_fingerprint)"
eq "build_inputs_fingerprint is 64 hex" "$(printf '%s' "$bfp" | wc -c | tr -d ' ')" "64"
eq "build_inputs_fingerprint matches artifact-status.sh fingerprint docker" \
   "$bfp" "$(scripts/artifact-status.sh fingerprint docker)"

# --- ghcr_ref / constants ---------------------------------------------
eq "ghcr_ref" "$(ghcr_ref v1.3.1)" "ghcr.io/esd-univr/hdl-course-toolchain:v1.3.1"
eq "REPO constant" "$REPO" "esd-univr/hdl-course-toolchain"
eq "IMAGE_BASE constant" "$IMAGE_BASE" "ghcr.io/esd-univr/hdl-course-toolchain"
eq "PLATFORM_DEFAULT constant" "$PLATFORM_DEFAULT" "linux/amd64"

echo
echo "release_lib: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
