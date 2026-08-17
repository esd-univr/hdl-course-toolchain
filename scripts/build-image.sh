#!/usr/bin/env bash
# Build the toolchain OCI image with every pin taken from versions.yml.
#
# Nothing here knows a version number. versions.py is the only thing that reads
# the manifest, and it fails if the manifest and the Containerfile disagree.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
toolchain="$(dirname "${here}")"

IMAGE="${HDL_TOOLCHAIN_IMAGE:-hdl-course-toolchain}"
TAG="${HDL_TOOLCHAIN_TAG:-spike}"
PLATFORM="${HDL_TOOLCHAIN_PLATFORM:-linux/amd64}"

mapfile -t build_args < <(python3 "${here}/versions.py" --format build-args | tr ' ' '\n')

echo "==> building ${IMAGE}:${TAG} for ${PLATFORM}"
docker buildx build \
    --platform "${PLATFORM}" \
    --file "${toolchain}/Containerfile" \
    --tag "${IMAGE}:${TAG}" \
    --load \
    "${build_args[@]}" \
    "$@" \
    "${toolchain}"
