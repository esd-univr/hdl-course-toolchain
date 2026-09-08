#!/usr/bin/env bash
# Tests for bin/hdl-toolchain. No network, no real Docker: HDL_TOOLCHAIN_DOCKER
# points at a stub that records its arguments and is told, through files in a
# scratch directory, whether an image is cached and whether a pull succeeds.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${HERE}/../bin/hdl-toolchain"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; [ $# -gt 1 ] && printf '    got: %s\n' "$2"; }
has()    { case "$2" in *"$3"*) ok ;; *) bad "$1 — expected to contain: $3" "$2" ;; esac; }
hasnot() { case "$2" in *"$3"*) bad "$1 — did not expect: $3" "$2" ;; *) ok ;; esac; }
eq()     { [ "$2" = "$3" ] && ok || bad "$1 — expected '$3'" "$2"; }

STUB_HOME=""
setup() {
    STUB_HOME="$(mktemp -d)"
    mkdir -p "${STUB_HOME}/ws"
    cat > "${STUB_HOME}/docker" <<'STUB'
#!/usr/bin/env bash
d="${DOCKER_STUB_DIR}"
case "$1" in
  info) [ -e "$d/no_daemon" ] && exit 1; exit 0 ;;
  image)
    # image inspect
    if [ -e "$d/has_image" ]; then
      case "$*" in
        *RepoDigests*) echo "ghcr.io/esd-univr/hdl-course-toolchain@sha256:abc123" ;;
        *.Id*)         echo "sha256:deadbeefcafe" ;;
        *.Created*)    echo "2026-09-08T10:00:00Z" ;;
      esac
      exit 0
    fi
    exit 1 ;;
  pull)
    echo "pull $*" >> "$d/pull.log"
    [ -e "$d/pull_fails" ] && exit 1
    touch "$d/has_image"
    exit 0 ;;
  run)
    echo "run $*" >> "$d/run.log"
    exit 0 ;;
  *) echo "stub: unhandled: $*" >&2; exit 99 ;;
esac
STUB
    chmod +x "${STUB_HOME}/docker"
    export DOCKER_STUB_DIR="${STUB_HOME}"
    export HDL_TOOLCHAIN_DOCKER="${STUB_HOME}/docker"
    export HDL_TOOLCHAIN_QUIET=""
}
teardown() { rm -rf "${STUB_HOME}"; unset DOCKER_STUB_DIR HDL_TOOLCHAIN_DOCKER; }
run_log()  { cat "${STUB_HOME}/run.log" 2>/dev/null || true; }
pull_log() { cat "${STUB_HOME}/pull.log" 2>/dev/null || true; }
launch()   { ( cd "${STUB_HOME}" && bash "${LAUNCHER}" "$@" ) 2>&1; }

echo "== hdl-toolchain launcher tests =="

# --- argument handling ------------------------------------------------------
setup
has "args/--version prints a version" "$(launch --version)" "hdl-toolchain 1."
launch --version >/dev/null 2>&1; eq "args/--version exits 0" "$?" "0"
has "args/missing --workspace is rejected" "$(launch -- zsh)" "--workspace is required"
has "args/missing command is rejected" "$(launch --workspace ws)" "no command given"
has "args/unknown option is rejected" "$(launch --nope --workspace ws -- zsh)" "unknown option"
has "args/bad --pull is rejected" "$(launch --pull sometimes --workspace ws -- zsh)" "--pull must be"
has "args/unknown HDL_TOOLCHAIN_* var is rejected" \
    "$(HDL_TOOLCHAIN_WRONG=1 launch --workspace ws -- zsh)" "unknown environment variable"
teardown

# --- image reference resolution -------------------------------------------
setup; touch "${STUB_HOME}/has_image"
launch --workspace ws -- zsh -l >/dev/null
has "ref/default is the official GHCR latest" "$(run_log)" "ghcr.io/esd-univr/hdl-course-toolchain:latest zsh -l"
teardown

setup; touch "${STUB_HOME}/has_image"
launch --image ghcr.io/esd-univr/hdl-course-toolchain:v1.3.0 --workspace ws -- make >/dev/null
has "ref/--image with a tag is used verbatim" "$(run_log)" "hdl-course-toolchain:v1.3.0 make"
teardown

setup; touch "${STUB_HOME}/has_image"
launch --image ghcr.io/esd-univr/hdl-course-toolchain@sha256:feed --workspace ws -- make >/dev/null
has "ref/--image with a digest is used verbatim" "$(run_log)" "hdl-course-toolchain@sha256:feed make"
eq  "ref/digest ref is not re-pulled when cached" "$(pull_log)" ""
teardown

setup; touch "${STUB_HOME}/has_image"
HDL_TOOLCHAIN_IMAGE=example.com/foo HDL_TOOLCHAIN_TAG=2.0 launch --workspace ws -- sh >/dev/null
has "ref/bare repo + HDL_TOOLCHAIN_TAG" "$(run_log)" "example.com/foo:2.0 sh"
teardown

# --- pull / offline behaviour --------------------------------------------
setup   # nothing cached, pull succeeds
launch --workspace ws -- zsh >/dev/null
has "pull/auto pulls when the image is absent" "$(pull_log)" "ghcr.io/esd-univr/hdl-course-toolchain:latest"
has "pull/run happens after a successful pull" "$(run_log)" "hdl-course-toolchain:latest zsh"
teardown

setup; touch "${STUB_HOME}/has_image"   # cached tag, pull still refreshes
launch --workspace ws -- zsh >/dev/null
has "pull/auto refreshes a cached moving tag" "$(pull_log)" "hdl-course-toolchain:latest"
teardown

setup; touch "${STUB_HOME}/has_image" "${STUB_HOME}/pull_fails"   # offline but cached
out="$(launch --workspace ws -- zsh)"
has "offline/cached image still runs" "$(run_log)" "hdl-course-toolchain:latest zsh"
has "offline/says it fell back to the cache" "$out" "cached image"
teardown

setup; touch "${STUB_HOME}/pull_fails"   # offline and nothing cached
out="$(launch --workspace ws -- zsh)"; rc=$?
eq  "offline/no cache is a hard error" "$rc" "3"
has "offline/no cache explains why" "$out" "cannot obtain"
eq  "offline/no cache does not run" "$(run_log)" ""
teardown

setup; touch "${STUB_HOME}/has_image"
launch --pull never --workspace ws -- zsh >/dev/null
eq  "pull/never never contacts the registry" "$(pull_log)" ""
has "pull/never still runs a cached image" "$(run_log)" "zsh"
teardown

setup   # --pull never with nothing cached
out="$(launch --pull never --workspace ws -- zsh)"; rc=$?
eq  "pull/never + no cache errors" "$rc" "3"
teardown

# --- platform -----------------------------------------------------------
setup; touch "${STUB_HOME}/has_image"
launch --workspace ws -- zsh >/dev/null
has "platform/default is linux/amd64 on run" "$(run_log)" "--platform linux/amd64"
has "platform/default is linux/amd64 on pull" "$(pull_log)" "--platform linux/amd64"
teardown

setup; touch "${STUB_HOME}/has_image"
launch --platform native --workspace ws -- zsh >/dev/null
hasnot "platform/native omits --platform on run" "$(run_log)" "--platform"
teardown

setup; touch "${STUB_HOME}/has_image"
launch --platform linux/arm64 --workspace ws -- zsh >/dev/null
has "platform/explicit override is honoured" "$(run_log)" "--platform linux/arm64"
teardown

# --- isolation defaults ------------------------------------------------
setup; touch "${STUB_HOME}/has_image"
log="$(launch --workspace ws -- zsh; run_log)"
has "isolation/read-only root"      "$(run_log)" "--read-only"
has "isolation/network denied"      "$(run_log)" "--network none"
has "isolation/workspace at /work"  "$(run_log)" "target=/work"
has "isolation/runs as the user"    "$(run_log)" "--user "
teardown

setup; touch "${STUB_HOME}/has_image"
launch --network --workspace ws -- zsh >/dev/null
hasnot "isolation/--network lifts the ban" "$(run_log)" "--network none"
teardown

# --- daemon detection -------------------------------------------------
setup; touch "${STUB_HOME}/no_daemon"
out="$(launch --workspace ws -- zsh)"; rc=$?
eq  "daemon/down is exit 3" "$rc" "3"
has "daemon/down explains" "$out" "not responding"
teardown

setup
out="$(HDL_TOOLCHAIN_DOCKER=/nonexistent/docker bash "${LAUNCHER}" --workspace "${STUB_HOME}/ws" -- zsh 2>&1)"; rc=$?
eq  "daemon/missing binary is exit 3" "$rc" "3"
has "daemon/missing binary explains" "$out" "not found on PATH"
has "daemon/missing binary does not offer to install docker" "$out" "does not install Docker"
teardown

echo
echo "passed: ${PASS}   failed: ${FAIL}"
[ "${FAIL}" -eq 0 ]
