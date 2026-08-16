#!/usr/bin/env bash
# Download the pinned source archives to toolchain/.out/sources/.
#
# The archives are fetched here rather than inside the image build. Large
# transfers from inside the container stalled repeatedly on this host while the
# same download from the host took seconds, so front-loading the fetch removes
# a flaky dependency from the critical path. It also makes the build's network
# use explicit and finite: after this step, the image build needs the network
# only for apt and pip.
#
# Every archive is verified against the SHA-256 recorded in versions.yml, and
# an archive already present with the right digest is not downloaded again.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
toolchain="$(dirname "${here}")"
sources="${toolchain}/.out/sources"

mkdir -p "${sources}"

status=0
while IFS=$'\t' read -r filename url digest; do
    [ -n "${filename}" ] || continue
    target="${sources}/${filename}"

    if [ -f "${target}" ] \
       && [ "$(sha256sum "${target}" | cut -d' ' -f1)" = "${digest}" ]; then
        echo "==> ${filename}: already present and verified"
        continue
    fi

    echo "==> ${filename}: fetching ${url}"
    if ! curl -fL --retry 5 --retry-delay 5 --retry-all-errors \
             --connect-timeout 30 --no-progress-meter -o "${target}.part" "${url}"; then
        echo "error: failed to download ${url}" >&2
        rm -f "${target}.part"
        status=1
        continue
    fi

    actual="$(sha256sum "${target}.part" | cut -d' ' -f1)"
    if [ "${actual}" != "${digest}" ]; then
        echo "error: SHA-256 mismatch for ${url}" >&2
        echo "  expected ${digest}" >&2
        echo "  actual   ${actual}" >&2
        rm -f "${target}.part"
        status=1
        continue
    fi
    mv "${target}.part" "${target}"
    echo "    verified ${digest}"
done < <(python3 "${here}/versions.py" --format sources)

exit "${status}"
