#!/usr/bin/env bash
# Report whether a built artifact matches the sources that define it.
#
# Make models file dependencies, but the OCI image and the SIF live outside the
# filesystem it tracks, so `make doctor` used to inspect whatever the tag
# happened to point at -- including an image built before the last change to
# versions.yml -- and report PASS for a tool version that is no longer pinned.
#
# The comparison is by content, not timestamp: a git checkout rewrites mtimes
# even when nothing changed, and a staleness check that cries wolf is one that
# gets ignored.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
toolchain="$(dirname "${here}")"

MODE="check"
[ "${1:-}" != "--record" ] || { MODE="record"; shift; }
ENGINE="${1:-docker}"

case "${ENGINE}" in
    docker)    stamp_file="${toolchain}/.out/build-inputs.docker.sha256" ;;
    apptainer) stamp_file="${toolchain}/.out/build-inputs.apptainer.sha256" ;;
    *) echo "error: unknown engine: ${ENGINE} (expected docker or apptainer)" >&2; exit 2 ;;
esac

# Everything that changes what the artifact should contain.
inputs() {
    printf '%s\n' \
        "${toolchain}/versions.yml" \
        "${toolchain}/Containerfile" \
        "${toolchain}/requirements.txt"
    find "${toolchain}/doctor" "${toolchain}/container" -type f 2>/dev/null | sort
}

fingerprint() {
    inputs | while IFS= read -r file; do
        [ -f "${file}" ] && sha256sum "${file}"
    done | sha256sum | cut -d' ' -f1
}

current=$(fingerprint)

if [ "${MODE}" = "record" ]; then
    mkdir -p "$(dirname "${stamp_file}")"
    printf '%s\n' "${current}" > "${stamp_file}"
    exit 0
fi

if [ ! -f "${stamp_file}" ]; then
    echo "error: no record of what ${ENGINE} artifact was built from" >&2
    case "${ENGINE}" in
        docker)    echo "       run 'make build' before trusting a doctor result" >&2 ;;
        apptainer) echo "       run 'make sif' before trusting a doctor result" >&2 ;;
    esac
    exit 1
fi

recorded=$(cat "${stamp_file}")
if [ "${current}" != "${recorded}" ]; then
    echo "error: the ${ENGINE} artifact was built from different sources" >&2
    printf '       built from  %s\n' "${recorded}" >&2
    printf '       sources now %s\n' "${current}" >&2
    inputs | while IFS= read -r file; do
        [ -f "${file}" ] || continue
        printf '       input: %s\n' "${file#"${toolchain}/"}" >&2
    done | head -3 >&2
    case "${ENGINE}" in
        docker)    echo "       run 'make build' before trusting a doctor result" >&2 ;;
        apptainer) echo "       run 'make sif' before trusting a doctor result" >&2 ;;
    esac
    exit 1
fi

printf '    OK  %s artifact matches its build inputs\n' "${ENGINE}"
