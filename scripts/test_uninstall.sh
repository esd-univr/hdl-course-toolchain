#!/usr/bin/env bash
# Tests for uninstall.sh. Never touches the real HOME; Docker is a stub that
# logs its arguments and answers from files in a scratch directory.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
UNINSTALL="${ROOT}/uninstall.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; [ $# -gt 1 ] && printf '    got: %s\n' "$2"; }
has()    { case "$2" in *"$3"*) ok ;; *) bad "$1 — expected to contain: $3" "$2" ;; esac; }
hasnot() { case "$2" in *"$3"*) bad "$1 — did not expect: $3" "$2" ;; *) ok ;; esac; }
eq()     { [ "$2" = "$3" ] && ok || bad "$1 — expected '$3'" "$2"; }

FAKE=""
setup() {
    FAKE="$(mktemp -d)"
    mkdir -p "${FAKE}/home/.local/bin" "${FAKE}/stub"
    printf '#!/bin/sh\necho stub\n' > "${FAKE}/home/.local/bin/hdl-toolchain"
    chmod 755 "${FAKE}/home/.local/bin/hdl-toolchain"
    cat > "${FAKE}/stub/docker" <<'STUB'
#!/usr/bin/env bash
d="${DOCKER_STUB_DIR}"
echo "$*" >> "$d/docker.log"
case "$1 $2" in
  "info ")  exit 0 ;;
  "ps -a")
     [ -e "$d/container" ] && echo "c1 ghcr.io/esd-univr/hdl-course-toolchain:latest laughing_hdl"
     exit 0 ;;
  "image ls")
     if [ -e "$d/has_image" ]; then
       case "$*" in
         *Repository*) echo "ghcr.io/esd-univr/hdl-course-toolchain:latest" ;;
         *.ID*)        echo "abc123def456" ;;
       esac
     fi
     exit 0 ;;
  "rmi "*|"image rmi"*) exit 0 ;;
  "image inspect"*) exit 0 ;;
esac
exit 0
STUB
    chmod +x "${FAKE}/stub/docker"
    export DOCKER_STUB_DIR="${FAKE}"
}
teardown() { rm -rf "${FAKE}"; unset DOCKER_STUB_DIR; }
dlog() { cat "${FAKE}/docker.log" 2>/dev/null || true; }

# default: no docker on PATH at all
run()      { HOME="${FAKE}/home" SHELL=/bin/bash PATH="/usr/bin:/bin" sh "$UNINSTALL" "$@" 2>&1; }
# with the docker stub on PATH
run_dk()   { HOME="${FAKE}/home" SHELL=/bin/bash PATH="${FAKE}/stub:/usr/bin:/bin" sh "$UNINSTALL" "$@" 2>&1; }

echo "== uninstall.sh tests =="

setup
has "args/--version prints a version" "$(run --version)" "v"
has "args/--help lists --purge-image" "$(run --help)" "--purge-image"
has "args/--help promises not to touch Docker" "$(run --help)" "never removes Docker"
has "args/unknown flag rejected" "$(run --frobnicate)" "unknown option"
run --frobnicate >/dev/null 2>&1; eq "args/unknown flag exits 1" "$?" "1"
teardown

setup
out="$(run)"
has "default/removes the launcher" "$out" "removed"
eq  "default/launcher is gone" "$([ -e "${FAKE}/home/.local/bin/hdl-toolchain" ] && echo yes || echo no)" "no"
out="$(run)"
has "default/idempotent second run" "$out" "no launcher at"
run >/dev/null 2>&1; eq "default/exits 0" "$?" "0"
teardown

setup
out="$(run --dry-run)"
has "dry-run/announces itself" "$out" "dry run"
has "dry-run/names the target" "$out" "hdl-toolchain"
eq  "dry-run/removed nothing" "$([ -x "${FAKE}/home/.local/bin/hdl-toolchain" ] && echo yes || echo no)" "yes"
teardown

setup   # custom bin dir
mkdir -p "${FAKE}/home/opt"
printf '#!/bin/sh\n' > "${FAKE}/home/opt/hdl-toolchain"; chmod 755 "${FAKE}/home/opt/hdl-toolchain"
out="$(HOME="${FAKE}/home" SHELL=/bin/bash HDL_TOOLCHAIN_BIN_DIR="${FAKE}/home/opt" PATH="/usr/bin:/bin" sh "$UNINSTALL" 2>&1)"
eq "bindir/honours HDL_TOOLCHAIN_BIN_DIR" "$([ -e "${FAKE}/home/opt/hdl-toolchain" ] && echo yes || echo no)" "no"
teardown

setup   # shell rc files are never edited
cat > "${FAKE}/home/.bashrc" <<'RC'
export EDITOR=vim

# added by hdl-toolchain installer
export PATH="$HOME/.local/bin:$PATH"
RC
before="$(cat "${FAKE}/home/.bashrc")"
out="$(run)"
eq  "rc/left byte-identical" "$(cat "${FAKE}/home/.bashrc")" "$before"
has "rc/mentions the leftover line" "$out" "remove it by hand"
teardown

setup   # --purge-image with no docker
out="$(HOME="${FAKE}/home" SHELL=/bin/bash HDL_TOOLCHAIN_DOCKER=/nonexistent/docker \
       sh "$UNINSTALL" --purge-image 2>&1)"; rc=$?
has "purge/no docker is handled" "$out" "docker not found"
eq  "purge/no docker still exits 0" "$rc" "0"
has "purge/no docker still removed the launcher" "$out" "removed"
teardown

setup; touch "${FAKE}/has_image"   # --purge-image, image present, no container
out="$(run_dk --purge-image)"
has "purge/removes the exact repo tag" "$(dlog)" "rmi ghcr.io/esd-univr/hdl-course-toolchain:latest"
has "purge/reports done" "$out" "only ghcr.io/esd-univr/hdl-course-toolchain"
teardown

setup; touch "${FAKE}/has_image" "${FAKE}/container"   # container in use
out="$(run_dk --purge-image)"
has "purge/in-use is reported" "$out" "these containers use"
hasnot "purge/in-use removes nothing" "$(dlog)" "rmi ghcr.io"
teardown

setup; touch "${FAKE}/has_image"   # dry-run + purge
out="$(run_dk --purge-image --dry-run)"
has "purge/dry-run shows the rmi" "$out" "would run: docker rmi ghcr.io/esd-univr/hdl-course-toolchain:latest"
hasnot "purge/dry-run runs no rmi" "$(dlog)" "rmi ghcr.io/esd-univr/hdl-course-toolchain:latest"
teardown

echo
echo "passed: ${PASS}   failed: ${FAIL}"
[ "${FAIL}" -eq 0 ]
