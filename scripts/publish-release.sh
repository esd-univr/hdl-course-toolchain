#!/usr/bin/env bash
# Phase 3 of a release: publish the already-qualified local image. NEVER builds.
# Resumable — safe to re-run after a network failure. See docs/releasing.md.
#
#   scripts/publish-release.sh vX.Y.Z
#
# This script publishes the *exact* image that `make qualify` locally qualified.
# It runs a validation gate first: every check below must pass before any
# network / registry / git write happens. It NEVER runs `docker build` /
# `make build` / `make fetch` — if there is no valid qualification record for
# the current tree it fails closed.
set -euo pipefail

_DIR="$(cd "$(dirname "$0")" && pwd)"
_ROOT="$(dirname "${_DIR}")"
# shellcheck source=scripts/release_lib.sh
. "${_DIR}/release_lib.sh"
cd "${_ROOT}"

VERSION="${1:-}"
case "${VERSION}" in
    v[0-9]*.[0-9]*.[0-9]*) : ;;
    *) die "usage: scripts/publish-release.sh vX.Y.Z" ;;
esac

RECORD=".out/qualification.json"
# PLATFORM comes from the record so a later push targets exactly the qualified
# platform; fall back to the default when the record is absent (the gate then
# aborts anyway).
PLATFORM="$(python3 -c 'import json;print(json.load(open(".out/qualification.json"))["platform"])' 2>/dev/null || echo "${PLATFORM_DEFAULT}")"
export PLATFORM

# --- validation gate --------------------------------------------------------
# Confirm the qualification record still describes the current tree, the current
# HEAD and the local Docker image. The binding identity is docker_image_id
# (sha256:…) — a matching :latest tag or revision label is never sufficient.
# All of version / version-file / head / tree-clean / both fingerprints /
# image-id are compared by one `qualification.py verify` call.
publish_validate() {
    [ -f "${RECORD}" ] \
        || die "no qualification record (${RECORD}) — run 'make qualify' first"

    local rec_ref image_id tree_clean
    rec_ref="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field docker_image_ref)" \
        || die "qualification record (${RECORD}) is missing or unreadable — run 'make qualify'"

    image_id="$(docker image inspect --format '{{.Id}}' "${rec_ref}" 2>/dev/null)" \
        || die "the qualified image ${rec_ref} is not present locally — run 'make qualify'"
    [ -n "${image_id}" ] \
        || die "the qualified image ${rec_ref} is not present locally — run 'make qualify'"

    tree_clean=1
    [ -z "$(git status --porcelain)" ] || tree_clean=0

    python3 "${_DIR}/qualification.py" verify \
        --record "${RECORD}" \
        --version "${VERSION}" \
        --version-file "$(cat VERSION)" \
        --head "$(git rev-parse HEAD)" \
        --tree-clean "${tree_clean}" \
        --build-inputs-sha256 "$(build_inputs_fingerprint)" \
        --release-inputs-sha256 "$(release_inputs_fingerprint)" \
        --image-id "${image_id}" \
        || die "qualification does not match the current tree / HEAD / image — re-run 'make qualify' on this commit"
}

# --- tooling / auth check --------------------------------------------------
# docker + gh must be present, docker usable, gh authenticated. This does not
# write anything: package-write permission is proven by the first real push
# (the :vX.Y.Z tag), added in a later task — the spec forbids probing it with a
# throwaway artifact.
require_tooling() {
    command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
    command -v gh     >/dev/null 2>&1 || die "gh not found on PATH — https://cli.github.com"
    docker info >/dev/null 2>&1       || die "docker is not running / not usable"
    gh auth status >/dev/null 2>&1    || die "gh is not authenticated — run: gh auth login"
}

main() {
    publish_validate
    require_tooling
    echo "publish: validation OK — ${VERSION} @ $(git rev-parse --short HEAD) (${PLATFORM})"
    # ---------------------------------------------------------------------
    # Tasks 9–12 continue below this line, all AFTER the gate above:
    #   9  — docker push  ${IMAGE_BASE}:${VERSION}   (first real registry write)
    #   10 — retag / push ${IMAGE_BASE}:latest
    #   11 — git tag ${VERSION} + push
    #   12 — gh release create ${VERSION}
    # ---------------------------------------------------------------------
}

main "$@"
