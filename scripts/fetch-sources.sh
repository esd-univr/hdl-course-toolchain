#!/usr/bin/env bash
# Download and verify the source archives pinned in versions.yml.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
toolchain="$(dirname "${here}")"
sources="${toolchain}/.out/sources"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    bold=$'\033[1m'
    green=$'\033[32m'
    cyan=$'\033[36m'
    yellow=$'\033[33m'
    red=$'\033[31m'
    reset=$'\033[0m'
else
    bold="" green="" cyan="" yellow="" red="" reset=""
fi

info()  { printf '%s==>%s %s\n' "${cyan}${bold}" "${reset}" "$*"; }
ok()    { printf '    %sOK%s  %s\n' "${green}${bold}" "${reset}" "$*"; }
warn()  { printf '    %s!!%s  %s\n' "${yellow}${bold}" "${reset}" "$*"; }
fail()  { printf '    %sERR%s %s\n' "${red}${bold}" "${reset}" "$*" >&2; }

mkdir -p "${sources}"

status=0
count=0
cached=0
fetched=0
while IFS=$'\t' read -r filename url digest; do
    [ -n "${filename}" ] || continue
    count=$((count + 1))
    target="${sources}/${filename}"

    info "${filename}"

    if [ -f "${target}" ] \
       && [ "$(sha256sum "${target}" | cut -d' ' -f1)" = "${digest}" ]; then
        ok "cached and verified"
        cached=$((cached + 1))
        continue
    fi

    printf '    source  %s\n' "${url}"
    if ! curl -fL --retry 5 --retry-delay 5 --retry-all-errors \
             --connect-timeout 30 --no-progress-meter -o "${target}.part" "${url}"; then
        fail "download failed"
        rm -f "${target}.part"
        status=1
        continue
    fi

    actual="$(sha256sum "${target}.part" | cut -d' ' -f1)"
    if [ "${actual}" != "${digest}" ]; then
        fail "SHA-256 mismatch"
        printf '        expected %s\n' "${digest}" >&2
        printf '        actual   %s\n' "${actual}" >&2
        rm -f "${target}.part"
        status=1
        continue
    fi

    mv "${target}.part" "${target}"
    ok "fetched and verified  ${digest}"
    fetched=$((fetched + 1))
done < <(python3 "${here}/versions.py" --format sources)

if [ "${status}" -eq 0 ]; then
    printf '\n%sSources ready:%s %d total, %d fetched, %d cached\n' \
        "${green}${bold}" "${reset}" "${count}" "${fetched}" "${cached}"
else
    warn "one or more sources failed; see errors above"
fi

exit "${status}"
