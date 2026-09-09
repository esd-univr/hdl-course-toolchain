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
trap 'cp "$tmp" "$ROOT/VERSION"; rm -f "$tmp"' EXIT
printf 'x\n' >> VERSION
fp2="$(release_inputs_fingerprint)"
[ "$fp1" != "$fp2" ] && ok || bad "fingerprint should change when VERSION changes"
cp "$tmp" VERSION

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
echo "== prepare-release.sh preconditions =="
setup_repo() {
  WORK="$(mktemp -d)"; export WORK
  git init -q -b main "$WORK/up.git" --bare
  git clone -q "$WORK/up.git" "$WORK/repo" 2>/dev/null
  cd "$WORK/repo" || exit 1
  git config user.email t@t; git config user.name t
  mkdir -p scripts bin
  cp "$ROOT/scripts/release_lib.sh" "$ROOT/scripts/prepare-release.sh" scripts/
  cp "$ROOT/scripts/artifact-status.sh" scripts/ 2>/dev/null || true
  printf '1.2.0\n' > VERSION
  printf 'LAUNCHER_VERSION="1.2.0"\n' > bin/hdl-toolchain
  printf 'VERSION="v0.0.0-dev"\nSHA256="x"\n' > install.sh
  printf 'VERSION="v0.0.0-dev"\n' > uninstall.sh
  git add -A; git commit -qm init; git push -q origin main
  mkdir "$WORK/stub"
  cat > "$WORK/stub/gh" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"release view"*) exit 1 ;;
  *"git/ref/tags/"*) echo '{"message":"Not Found"}'; exit 1 ;;
  *) exit 0 ;;
esac
S
  cat > "$WORK/stub/docker" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"imagetools inspect"*) exit 1 ;;
  *"manifest inspect"*) exit 1 ;;
  *) exit 0 ;;
esac
S
  chmod +x "$WORK/stub"/*
  export PATH="$WORK/stub:$PATH"
}
teardown_repo() { cd "$ROOT" || exit 1; rm -rf "$WORK"; }

setup_repo
out="$(bash scripts/prepare-release.sh not-a-version 2>&1)"; neq0 "bad version rejected" "$?"
has "bad version message" "$out" "vX.Y.Z"
git switch -qc side
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "not on main rejected" "$?"
has "not-on-main message" "$out" "main"
git switch -qm main >/dev/null 2>&1 || git switch -q main
echo dirt > dirty; git add dirty
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "dirty tree rejected" "$?"
git reset -q --hard >/dev/null
# ahead of origin/main
git commit -q --allow-empty -m ahead
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "ahead of origin rejected" "$?"
has "ahead message" "$out" "origin/main"
git reset -q --hard origin/main
# clean main at origin/main, dev sentinel, version unused -> preconditions pass
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; eq "preconditions pass on clean main" "$?" "0"
has "preconditions-ok message" "$out" "preconditions OK"
# a local tag for the target version aborts version_unused
git tag v1.3.1
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "existing local tag rejected" "$?"
has "local tag message" "$out" "already exists locally"
git tag -d v1.3.1 >/dev/null
# dev sentinel gone from origin (a release half-pinned) aborts, even with
# HEAD exactly on origin/main
printf 'VERSION="v1.3.1"\nSHA256="x"\n' > install.sh
git commit -qam "wip pin"; git push -q origin main
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "missing dev sentinel rejected" "$?"
has "sentinel message" "$out" "sentinel"
git reset -q --hard HEAD~1; git push -qf origin main
# idempotent resume: HEAD is the matching release commit, parent == origin/main
printf 'VERSION="v1.3.1"\nSHA256="x"\n' > install.sh
printf 'VERSION="v1.3.1"\n' > uninstall.sh
printf 'LAUNCHER_VERSION="1.3.1"\n' > bin/hdl-toolchain
printf '1.3.1\n' > VERSION
git commit -qam "release: v1.3.1"
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; eq "resume exits 0" "$?" "0"
has "resume message" "$out" "already prepared at HEAD"
git reset -q --hard origin/main
teardown_repo

echo
echo "release_lib: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
