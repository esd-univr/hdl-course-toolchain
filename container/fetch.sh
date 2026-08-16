#!/bin/sh
# Fetch a pinned source archive or git ref, with retries and integrity checking.
#
# Image builds pull several large sources, and a single flaky transfer should
# not cost a whole build. Cloning large repositories from inside the build
# repeatedly stalled here, so archives are preferred and are pinned by SHA-256:
# a digest is a stronger identity than a tag, because a tag can be moved.
#
# Usage:
#   fetch.sh --local  <digest> <archive-path> <destination> [--strip-components=N]
#   fetch.sh --sha256 <digest> <archive-url>  <destination> [--strip-components=N]
#   fetch.sh --git    <repository-url> <ref>  <destination>
#
# For --git, <ref> may be a tag, branch or full commit SHA; the ref is fetched
# explicitly rather than passed to --branch, which does not accept a SHA.
set -eu

attempts=3

retry() {
    attempt=1
    delay=5
    while : ; do
        if "$@"; then
            return 0
        fi
        if [ "${attempt}" -ge "${attempts}" ]; then
            echo "fetch.sh: giving up after ${attempts} attempts: $*" >&2
            return 1
        fi
        echo "fetch.sh: attempt ${attempt} failed, retrying in ${delay}s" >&2
        attempt=$((attempt + 1))
        sleep "${delay}"
        delay=$((delay * 2))
    done
}

verify_and_extract() {
    archive="$1"
    digest="$2"
    destination="$3"
    strip="$4"

    actual="$(sha256sum "${archive}" | cut -d' ' -f1)"
    if [ "${actual}" != "${digest}" ]; then
        echo "fetch.sh: SHA-256 mismatch for ${archive}" >&2
        echo "  expected ${digest}" >&2
        echo "  actual   ${actual}" >&2
        return 1
    fi
    mkdir -p "${destination}"
    # shellcheck disable=SC2086  # strip is a single optional flag or empty
    tar -xzf "${archive}" -C "${destination}" ${strip}
    echo "fetch.sh: ${archive} -> ${destination} (sha256 ${digest})"
}

case "${1:-}" in
--local)
    digest="$2"
    archive="$3"
    destination="$4"
    strip="${5:-}"
    [ -n "${digest}" ] || { echo "fetch.sh: empty digest for ${archive}" >&2; exit 2; }
    [ -f "${archive}" ] || {
        echo "fetch.sh: missing ${archive}; run 'make toolchain-sources' first" >&2
        exit 2
    }
    verify_and_extract "${archive}" "${digest}" "${destination}" "${strip}"
    ;;
--sha256)
    digest="$2"
    url="$3"
    destination="$4"
    strip="${5:-}"

    [ -n "${digest}" ] || { echo "fetch.sh: empty --sha256 digest for ${url}" >&2; exit 2; }

    archive=/tmp/fetch-archive.tar.gz
    rm -f "${archive}"
    # --retry-all-errors also retries a connection that dies mid-transfer,
    # which is the failure mode seen here.
    retry curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors \
        --connect-timeout 30 --speed-limit 1000 --speed-time 60 \
        -o "${archive}" "${url}"

    verify_and_extract "${archive}" "${digest}" "${destination}" "${strip}"
    rm -f "${archive}"
    ;;
--git)
    url="$2"
    ref="$3"
    destination="$4"

    git init -q "${destination}"
    git -C "${destination}" remote add origin "${url}"
    # Give up on a connection that stalls below 1 KiB/s for 60s, then retry,
    # rather than sitting on a dead socket for twenty minutes.
    git -C "${destination}" config http.lowSpeedLimit 1000
    git -C "${destination}" config http.lowSpeedTime 60

    retry git -C "${destination}" fetch -q --depth 1 origin "${ref}"
    git -C "${destination}" checkout -q FETCH_HEAD
    echo "fetch.sh: ${url} ${ref} -> $(git -C "${destination}" rev-parse HEAD)"
    ;;
*)
    echo "fetch.sh: expected --sha256 or --git as the first argument" >&2
    exit 2
    ;;
esac
