#!/usr/bin/env bash
# Keep the SHA256= line in install.sh equal to the SHA-256 of bin/hdl-toolchain.
# A release whose installer pins the wrong launcher digest cannot install
# itself, so `make check` and CI verify this.
#
#   scripts/sync-installer-digest.sh           rewrite install.sh in place
#   scripts/sync-installer-digest.sh --check   fail if it would change anything
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
launcher="${root}/bin/hdl-toolchain"
installer="${root}/install.sh"
mode="write"
[ "${1:-}" != "--check" ] || mode="check"

digest_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

digest="$(digest_of "${launcher}")"
current="$(sed -n 's/^SHA256="\(.*\)"$/\1/p' "${installer}")"

if [ "${mode}" = "check" ]; then
    if [ "${current}" = "${digest}" ]; then
        echo "OK  install.sh pins ${digest}"
        exit 0
    fi
    echo "ERR install.sh pins ${current:-<none>}, launcher is ${digest}" >&2
    echo "    run: scripts/sync-installer-digest.sh" >&2
    exit 1
fi

tmp="$(mktemp)"
sed "s/^SHA256=\".*\"\$/SHA256=\"${digest}\"/" "${installer}" > "${tmp}"
grep -q "^SHA256=\"${digest}\"\$" "${tmp}" \
    || { rm -f "${tmp}"; echo "sync-installer-digest: SHA256 line not found in install.sh" >&2; exit 1; }
mv "${tmp}" "${installer}"
chmod 0755 "${installer}"
echo "install.sh SHA256 = ${digest}  (bin/hdl-toolchain)"
