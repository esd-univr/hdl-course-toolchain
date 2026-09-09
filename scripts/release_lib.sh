#!/usr/bin/env bash
# Shared helpers for prepare-release.sh and publish-release.sh. Source, do not
# execute:  . "$(dirname "$0")/release_lib.sh"
#
# Every helper is safe to source under `set -euo pipefail`. Helpers that probe
# git/gh/the registry `return 1` (with empty stdout) when the thing they look
# for is absent; callers that must not abort on that guard the call with
# `if helper; then` or `|| true`.
# shellcheck shell=bash

REPO="esd-univr/hdl-course-toolchain"
IMAGE_BASE="ghcr.io/esd-univr/hdl-course-toolchain"
PLATFORM_DEFAULT="linux/amd64"

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT="$(dirname "${_LIB_DIR}")"

die() { echo "release: $*" >&2; exit 1; }

ghcr_ref() { printf '%s:%s\n' "${IMAGE_BASE}" "$1"; }

# sha256 over the files the release artifact is cut from -- same construction as
# artifact-status.sh's fingerprint: sha256sum each existing file, then hash the
# list of lines.
release_inputs_fingerprint() {
    local f
    { for f in VERSION bin/hdl-toolchain install.sh uninstall.sh; do
        [ -f "${_ROOT}/${f}" ] && sha256sum "${_ROOT}/${f}"
      done; } | sha256sum | cut -d' ' -f1
}

# The docker build-input fingerprint (versions.yml, Containerfile, requirements,
# doctor/, container/), delegated to artifact-status.sh so there is one
# construction to keep in sync.
build_inputs_fingerprint() {
    "${_LIB_DIR}/artifact-status.sh" fingerprint docker
}

gh_release_exists() { gh release view "$1" >/dev/null 2>&1; }

# The commit sha the origin tag <version> resolves to, dereferencing an
# annotated tag object. Empty + return 1 when the tag does not exist on origin.
origin_tag_object_sha() {
    local ref typ sha
    ref="$(gh api "repos/${REPO}/git/ref/tags/$1" 2>/dev/null)" || return 1
    typ="$(printf '%s' "${ref}" | python3 -c 'import sys, json; print(json.load(sys.stdin)["object"]["type"])')" || return 1
    sha="$(printf '%s' "${ref}" | python3 -c 'import sys, json; print(json.load(sys.stdin)["object"]["sha"])')" || return 1
    if [ "${typ}" = "tag" ]; then
        gh api "repos/${REPO}/git/tags/${sha}" --jq '.object.sha' 2>/dev/null || return 1
    else
        printf '%s\n' "${sha}"
    fi
}

# The registry manifest digest of :<version>. Empty + return 1 when the tag is
# absent from the registry.
ghcr_manifest_digest() {
    docker buildx imagetools inspect "$(ghcr_ref "$1")" \
        --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"' | grep . || return 1
}

# The local image id after pulling <ref> for <platform>. Empty + return 1 when
# the pull fails (tag absent, offline, ...).
remote_image_id() {
    local ref platform
    ref="$(ghcr_ref "$1")"
    platform="${2:-$PLATFORM_DEFAULT}"
    docker pull --platform "${platform}" "${ref}" >/dev/null 2>&1 || return 1
    docker image inspect --format '{{.Id}}' "${ref}" 2>/dev/null || return 1
}
