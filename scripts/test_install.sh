#!/usr/bin/env bash
# Tests for install.sh. Never touches the real HOME, never uses the network:
# every case runs against a temp HOME with the payload injected from disk via
# HDL_TOOLCHAIN_PAYLOAD_FILE (the digest is still verified).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
INSTALLER="${1:-${ROOT}/install.sh}"
PAYLOAD="${ROOT}/bin/hdl-toolchain"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; [ $# -gt 1 ] && printf '    got: %s\n' "$2"; }
has()    { case "$2" in *"$3"*) ok ;; *) bad "$1 — expected to contain: $3" "$2" ;; esac; }
hasnot() { case "$2" in *"$3"*) bad "$1 — did not expect: $3" "$2" ;; *) ok ;; esac; }
eq()     { [ "$2" = "$3" ] && ok || bad "$1 — expected '$3'" "$2"; }

sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# The installer pins a digest. Pin it to the current launcher for the run so we
# exercise the real path, exactly as scripts/sync-installer-digest.sh will.
PINNED_INSTALLER=""
FAKE=""
setup() {
    FAKE="$(mktemp -d)"
    PINNED_INSTALLER="${FAKE}/install.sh"
    digest="$(sha_of "$PAYLOAD")"
    sed "s/^SHA256=\".*\"\$/SHA256=\"${digest}\"/" "$INSTALLER" > "$PINNED_INSTALLER"
    mkdir -p "${FAKE}/home"
}
teardown() { rm -rf "$FAKE"; }

# Runs the installer with a fake HOME, a fake SHELL, and the payload from disk.
installer() {
    HOME="${FAKE}/home" \
    SHELL="/bin/bash" \
    HDL_TOOLCHAIN_PAYLOAD_FILE="$PAYLOAD" \
        sh "$PINNED_INSTALLER" "$@" 2>&1
}

echo "== install.sh tests =="

# --- arguments / help ------------------------------------------------------
setup
has "args/--version prints a version" "$(installer --version)" "v"
installer --version >/dev/null 2>&1; eq "args/--version exits 0" "$?" "0"
has "args/--help mentions --uninstall" "$(installer --help)" "--uninstall"
has "args/unknown flag rejected" "$(installer --nope)" "unknown option"
installer --nope >/dev/null 2>&1; eq "args/unknown flag exits 1" "$?" "1"
teardown

# --- a clean install -----------------------------------------------------
setup
out="$(installer)"
has "install/reports success" "$out" "installed"
eq  "install/target exists" "$([ -f "${FAKE}/home/.local/bin/hdl-toolchain" ] && echo yes)" "yes"
eq  "install/target is executable" "$([ -x "${FAKE}/home/.local/bin/hdl-toolchain" ] && echo yes)" "yes"
eq  "install/target matches payload" \
    "$(sha_of "${FAKE}/home/.local/bin/hdl-toolchain")" "$(sha_of "$PAYLOAD")"
has "install/adds PATH line to .bashrc" "$(cat "${FAKE}/home/.bashrc" 2>/dev/null)" ".local/bin"
teardown

# --- checksum failure --------------------------------------------------
setup
tampered="${FAKE}/tampered"
cat "$PAYLOAD" > "$tampered"; printf '\n# tampered\n' >> "$tampered"
out="$(HOME="${FAKE}/home" SHELL=/bin/bash HDL_TOOLCHAIN_PAYLOAD_FILE="$tampered" sh "$PINNED_INSTALLER" 2>&1)"
rc=$?
has "checksum/mismatch is reported" "$out" "SHA-256 mismatch"
has "checksum/mismatch shows expected" "$out" "expected:"
eq  "checksum/mismatch exits 1" "$rc" "1"
eq  "checksum/mismatch installed nothing" \
    "$([ -e "${FAKE}/home/.local/bin/hdl-toolchain" ] && echo yes || echo no)" "no"
teardown

# --- idempotency / update -------------------------------------------
setup
installer >/dev/null
first_rc="${FAKE}/home/.bashrc"
first_rc_content="$(cat "$first_rc")"
out="$(installer)"
has "idempotent/second run says up to date" "$out" "up to date"
eq  "idempotent/rc file not appended twice" "$(cat "$first_rc")" "$first_rc_content"
teardown

setup   # an older launcher on disk must be replaced
mkdir -p "${FAKE}/home/.local/bin"
printf '#!/bin/sh\necho old\n' > "${FAKE}/home/.local/bin/hdl-toolchain"
chmod 755 "${FAKE}/home/.local/bin/hdl-toolchain"
out="$(installer)"
has "update/replaces an older launcher" "$out" "installed"
eq  "update/now matches the payload" \
    "$(sha_of "${FAKE}/home/.local/bin/hdl-toolchain")" "$(sha_of "$PAYLOAD")"
teardown

# --- PATH handling --------------------------------------------------
setup   # BIN_DIR already on PATH: no rc file written
out="$(HOME="${FAKE}/home" SHELL=/bin/bash PATH="${FAKE}/home/.local/bin:${PATH}" \
       HDL_TOOLCHAIN_PAYLOAD_FILE="$PAYLOAD" sh "$PINNED_INSTALLER" 2>&1)"
has "path/already on PATH is noted" "$out" "already on PATH"
eq  "path/no rc file created" "$([ -e "${FAKE}/home/.bashrc" ] && echo yes || echo no)" "no"
teardown

setup   # --no-modify-path prints the line but writes no rc file
out="$(installer --no-modify-path)"
has "path/--no-modify-path prints the export line" "$out" "export PATH="
eq  "path/--no-modify-path writes no rc file" "$([ -e "${FAKE}/home/.bashrc" ] && echo yes || echo no)" "no"
teardown

setup   # zsh users get .zshrc
out="$(HOME="${FAKE}/home" SHELL=/bin/zsh HDL_TOOLCHAIN_PAYLOAD_FILE="$PAYLOAD" sh "$PINNED_INSTALLER" 2>&1)"
has "path/zsh shell uses .zshrc" "$(cat "${FAKE}/home/.zshrc" 2>/dev/null)" ".local/bin"
teardown

# --- custom bin dir ------------------------------------------------
setup
out="$(HOME="${FAKE}/home" SHELL=/bin/bash HDL_TOOLCHAIN_BIN_DIR="${FAKE}/home/bin" \
       HDL_TOOLCHAIN_PAYLOAD_FILE="$PAYLOAD" sh "$PINNED_INSTALLER" 2>&1)"
eq "bindir/honours HDL_TOOLCHAIN_BIN_DIR" \
   "$([ -x "${FAKE}/home/bin/hdl-toolchain" ] && echo yes)" "yes"
teardown

# --- dry-run / uninstall ------------------------------------------
setup
out="$(installer --dry-run)"
has "dry-run/announces itself" "$out" "dry-run"
eq  "dry-run/wrote nothing" "$([ -e "${FAKE}/home/.local/bin/hdl-toolchain" ] && echo yes || echo no)" "no"
installer --dry-run >/dev/null 2>&1; eq "dry-run/exits 0" "$?" "0"
teardown

setup
installer >/dev/null
out="$(installer --uninstall)"
has "uninstall/says so" "$out" "removed"
eq  "uninstall/file is gone" "$([ -e "${FAKE}/home/.local/bin/hdl-toolchain" ] && echo yes || echo no)" "no"
installer --uninstall >/dev/null 2>&1; eq "uninstall/is idempotent, exits 0" "$?" "0"
teardown

echo
echo "passed: ${PASS}   failed: ${FAIL}"
[ "${FAIL}" -eq 0 ]
