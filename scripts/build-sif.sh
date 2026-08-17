#!/usr/bin/env bash
# Derive the Apptainer SIF from the already-built OCI image.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
toolchain="$(dirname "${here}")"
out="${toolchain}/.out"
TAG="${HDL_TOOLCHAIN_TAG:-latest}"
SIF="${HDL_TOOLCHAIN_SIF:-${out}/hdl-course-toolchain.sif}"
archive="${out}/hdl-course-toolchain-${TAG}.tar"
template="${toolchain}/apptainer/hdl-course-toolchain.def"

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

"${here}/export-oci.sh"
archive="$(cd "$(dirname "${archive}")" && pwd)/$(basename "${archive}")"
mkdir -p "$(dirname "${SIF}")"
sed "s|{{ARCHIVE}}|${archive}|g" "${template}" > "${tmp}"

echo "==> building ${SIF} from ${archive}"
apptainer build --force "${SIF}" "${tmp}"
