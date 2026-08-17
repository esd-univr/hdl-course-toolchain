#!/usr/bin/env bash
# Export the built OCI image to a docker-archive tarball for Apptainer.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(dirname "${here}")/.out"
mkdir -p "${out}"

IMAGE="${HDL_TOOLCHAIN_IMAGE:-hdl-course-toolchain}"
TAG="${HDL_TOOLCHAIN_TAG:-latest}"
archive="${out}/hdl-course-toolchain-${TAG}.tar"

echo "==> exporting ${IMAGE}:${TAG} to ${archive}"
docker save --output "${archive}" "${IMAGE}:${TAG}"
ls -lh "${archive}"
