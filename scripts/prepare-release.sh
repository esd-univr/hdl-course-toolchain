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

# True (0) when the target version is already claimed somewhere — a local tag, an
# origin tag, a GitHub Release, or a GHCR image. Prints the specific conflict to
# stderr. Non-fatal: safe to call in `if`/`&&`/`||` context under `set -e`.
version_in_use() {
    if git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null 2>&1; then
        echo "release: tag ${VERSION} already exists locally" >&2
        return 0
    fi
    if origin_tag_object_sha "${VERSION}" >/dev/null 2>&1; then
        echo "release: tag ${VERSION} already exists on origin" >&2
        return 0
    fi
    if gh_release_exists "${VERSION}"; then
        echo "release: a GitHub Release ${VERSION} already exists" >&2
        return 0
    fi
    if ghcr_manifest_digest "${VERSION}" >/dev/null 2>&1; then
        echo "release: $(ghcr_ref "${VERSION}") already exists in GHCR — pick the next version" >&2
        return 0
    fi
    return 1
}

prepare_already_done() {
    # HEAD is a matching release commit whose parent is origin/main, tree clean,
    # and the version is not otherwise claimed (tag/Release/GHCR).
    [ -z "$(git status --porcelain)" ] || return 1
    [ "$(git log -1 --format=%s)" = "release: ${VERSION}" ] || return 1
    [ "$(git rev-parse HEAD^)" = "$(git rev-parse origin/main)" ] || return 1
    grep -qx "VERSION=\"${VERSION}\"" install.sh || return 1
    grep -qx "VERSION=\"${VERSION}\"" uninstall.sh || return 1
    grep -qx "LAUNCHER_VERSION=\"${BARE}\"" bin/hdl-toolchain || return 1
    [ "$(cat VERSION)" = "${BARE}" ] || return 1
    ! version_in_use
}

prepare_preconditions() {
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "${branch}" = "main" ] || die "not on main (on ${branch})"
    [ -z "$(git status --porcelain)" ] || die "working tree is dirty"
    git fetch --quiet origin \
        || die "git fetch origin failed — check network / SSH access to origin"
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
        || die "HEAD is not exactly origin/main — pull/push/align main first"
    grep -qx 'VERSION="v0.0.0-dev"' install.sh \
        || die "install.sh is not at the v0.0.0-dev sentinel — a release is already half-pinned"
    if version_in_use; then
        die "version ${VERSION} is already in use (see above)"
    fi
}

pin_version() {
    printf '%s\n' "${BARE}" > VERSION
    sed -i.bak "s/^LAUNCHER_VERSION=\".*\"\$/LAUNCHER_VERSION=\"${BARE}\"/" bin/hdl-toolchain
    sed -i.bak "s/^VERSION=\".*\"\$/VERSION=\"${VERSION}\"/" install.sh
    sed -i.bak "s/^VERSION=\".*\"\$/VERSION=\"${VERSION}\"/" uninstall.sh
    rm -f bin/hdl-toolchain.bak install.sh.bak uninstall.sh.bak
    ./scripts/sync-installer-digest.sh
    grep -qx "LAUNCHER_VERSION=\"${BARE}\"" bin/hdl-toolchain || die "failed to pin the launcher"
    grep -qx "VERSION=\"${VERSION}\"" install.sh || die "failed to pin install.sh"
    grep -qx "VERSION=\"${VERSION}\"" uninstall.sh || die "failed to pin uninstall.sh"
    [ "$(cat VERSION)" = "${BARE}" ] || die "failed to pin VERSION"
}

main() {
    if prepare_already_done; then
        echo "prepare: already prepared at HEAD $(git rev-parse --short HEAD) (${VERSION})"
        exit 0
    fi
    prepare_preconditions
    echo "prepare: preconditions OK for ${VERSION} — pinning"
    pin_version
    echo "prepare: running fast tests against the pinned tree"
    make --no-print-directory check
    make --no-print-directory test
    git add VERSION bin/hdl-toolchain install.sh uninstall.sh
    git commit -m "release: ${VERSION}"
    cat <<EOF

prepare: committed "release: ${VERSION}" at $(git rev-parse --short HEAD)

Next:
  make qualify
  make publish VERSION=${VERSION}

Not yet done (publish does these): git tag, push, GHCR, GitHub Release.
EOF
}

main "$@"
