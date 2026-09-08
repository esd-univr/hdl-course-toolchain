#!/usr/bin/env bash
# Build the toolchain OCI image with every pin taken from versions.yml.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
toolchain="$(dirname "${here}")"

IMAGE="${HDL_TOOLCHAIN_IMAGE:-hdl-course-toolchain}"
TAG="${HDL_TOOLCHAIN_TAG:-latest}"
PLATFORM="${HDL_TOOLCHAIN_PLATFORM:-linux/amd64}"
# Human-facing image version for the OCI label; the release workflow sets it to
# the release tag. Defaults to the VERSION file for local builds.
IMAGE_VERSION="${HDL_TOOLCHAIN_IMAGE_VERSION:-$(cat "${toolchain}/VERSION" 2>/dev/null || echo dev)}"
REVISION="$(git -C "${toolchain}" rev-parse HEAD 2>/dev/null || echo unknown)"

mapfile -t build_args < <(python3 "${here}/versions.py" --format build-args | tr ' ' '\n')

echo "==> building ${IMAGE}:${TAG} for ${PLATFORM}"
docker buildx build \
    --platform "${PLATFORM}" \
    --file "${toolchain}/Containerfile" \
    --tag "${IMAGE}:${TAG}" \
    --label "org.opencontainers.image.title=hdl-course-toolchain" \
    --label "org.opencontainers.image.description=Reproducible HDL/EDA course toolchain (University of Verona)" \
    --label "org.opencontainers.image.source=https://github.com/esd-univr/hdl-course-toolchain" \
    --label "org.opencontainers.image.version=${IMAGE_VERSION}" \
    --label "org.opencontainers.image.revision=${REVISION}" \
    --label "org.opencontainers.image.licenses=MIT" \
    --load \
    "${build_args[@]}" \
    "$@" \
    "${toolchain}"

# Record what this image was built from, so `make doctor` can refuse to inspect
# an artifact that no longer matches its sources.
"${here}/artifact-status.sh" --record docker
