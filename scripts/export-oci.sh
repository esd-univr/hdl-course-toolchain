#!/usr/bin/env bash
# Export the built OCI image to a docker-archive tarball for Apptainer.
#
# docker-archive rather than docker-daemon:// on purpose: it decouples the SIF
# build from a running daemon, which is what makes the conversion reproducible
# on a university machine where the two may not both be available.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(dirname "${here}")/.out"
mkdir -p "${out}"

IMAGE="${STC_IMAGE:-stc-toolchain}"
TAG="${STC_TAG:-spike}"
archive="${out}/stc-toolchain-${TAG}.tar"

echo "==> exporting ${IMAGE}:${TAG} to ${archive}"
docker save --output "${archive}" "${IMAGE}:${TAG}"
ls -lh "${archive}"
