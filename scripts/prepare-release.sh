#!/usr/bin/env bash
# Phase 1 of a release: pin the version and commit "release: vX.Y.Z". Nothing
# else — no tag, no push, no GHCR, no GitHub Release. See docs/releasing.md.
#
#   scripts/prepare-release.sh vX.Y.Z
set -euo pipefail

_DIR="$(cd "$(dirname "$0")" && pwd)"
_ROOT="$(dirname "${_DIR}")"
# shellcheck source=scripts/release_lib.sh
. "${_DIR}/release_lib.sh"
cd "${_ROOT}"

VERSION="${1:-}"
case "${VERSION}" in
    v[0-9]*.[0-9]*.[0-9]*) : ;;
    *) die "usage: scripts/prepare-release.sh vX.Y.Z" ;;
esac
BARE="${VERSION#v}"

prepare_already_done() {
    # HEAD is a matching release commit whose parent is origin/main, tree clean.
    [ -z "$(git status --porcelain)" ] || return 1
    [ "$(git log -1 --format=%s)" = "release: ${VERSION}" ] || return 1
    [ "$(git rev-parse HEAD^)" = "$(git rev-parse origin/main)" ] || return 1
    grep -qx "VERSION=\"${VERSION}\"" install.sh || return 1
    grep -qx "VERSION=\"${VERSION}\"" uninstall.sh || return 1
    grep -qx "LAUNCHER_VERSION=\"${BARE}\"" bin/hdl-toolchain || return 1
    [ "$(cat VERSION)" = "${BARE}" ] || return 1
}

version_unused() {
    git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null 2>&1 \
        && die "tag ${VERSION} already exists locally"
    origin_tag_object_sha "${VERSION}" >/dev/null 2>&1 \
        && die "tag ${VERSION} already exists on origin"
    gh_release_exists "${VERSION}" \
        && die "a GitHub Release ${VERSION} already exists"
    if ghcr_manifest_digest "${VERSION}" >/dev/null 2>&1; then
        die "$(ghcr_ref "${VERSION}") already exists in GHCR — pick the next version"
    fi
}

prepare_preconditions() {
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "${branch}" = "main" ] || die "not on main (on ${branch})"
    [ -z "$(git status --porcelain)" ] || die "working tree is dirty"
    git fetch --quiet origin
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
        || die "HEAD is not exactly origin/main — pull/push/align main first"
    grep -qx 'VERSION="v0.0.0-dev"' install.sh \
        || die "install.sh is not at the v0.0.0-dev sentinel — a release is already half-pinned"
    version_unused
}

main() {
    if prepare_already_done; then
        echo "prepare: already prepared at HEAD $(git rev-parse --short HEAD) (${VERSION})"
        exit 0
    fi
    prepare_preconditions
    echo "prepare: preconditions OK for ${VERSION}"
    # Task 7 adds the pinning + commit below this line.
}

main "$@"
