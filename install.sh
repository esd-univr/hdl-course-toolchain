#!/bin/sh
#
# install.sh - installer for the hdl-toolchain launcher
#              (https://github.com/esd-univr/hdl-course-toolchain)
#
# One-time student setup:
#   curl -fsSL https://github.com/esd-univr/hdl-course-toolchain/releases/latest/download/install.sh | bash
#
# The safer habit is to read it first:
#   curl -fsSL https://github.com/esd-univr/hdl-course-toolchain/releases/latest/download/install.sh -o install.sh
#   less install.sh && sh install.sh
#
# It installs ONE file, ~/.local/bin/hdl-toolchain, and - only if that
# directory is not already on PATH - adds one line to your shell rc file.
# Nothing else is touched. It does not install Docker.
#
# Deliberately POSIX sh: it runs under the stock macOS /bin/sh and needs no
# GNU coreutils, no bash 4, and no jq.

set -u

# --- pinned by scripts/release.sh when a release is cut -------------------
VERSION="v1.3.1"
SHA256="ed32305739d91a2fc452805509e2b4c6272527bc06d7910bf55f37a4a24be699"
# ------------------------------------------------------------------------

REPO="esd-univr/hdl-course-toolchain"
ASSET="hdl-toolchain"

BIN_DIR="${HDL_TOOLCHAIN_BIN_DIR:-${HOME}/.local/bin}"
TARGET="${BIN_DIR}/hdl-toolchain"

DRY_RUN=0
MODIFY_PATH=1
ACTION="install"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf 'dry-run: %s\n' "$*"; else eval "$*"; fi; }

usage() {
    cat <<USAGE
hdl-toolchain installer ${VERSION}

  install.sh                 install or update hdl-toolchain
  install.sh --dry-run       print what would happen, write nothing
  install.sh --no-modify-path  install only; never touch a shell rc file
  install.sh --uninstall     remove hdl-toolchain
  install.sh --version       print the version this installer pins
  install.sh --help          this text

Environment:
  HDL_TOOLCHAIN_BIN_DIR      install directory (default ~/.local/bin)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)         DRY_RUN=1 ;;
        --no-modify-path)   MODIFY_PATH=0 ;;
        --uninstall)        ACTION="uninstall" ;;
        --version)          printf '%s\n' "$VERSION"; exit 0 ;;
        -h|--help)          usage; exit 0 ;;
        *)                  die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        die "neither sha256sum nor shasum found - cannot verify the download"
    fi
}

preflight() {
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || die "neither curl nor wget found - install one and run this again"
}

fetch() {
    # $1 url  $2 dest
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    else
        wget -qO "$2" "$1"
    fi
}

uninstall() {
    if [ -e "$TARGET" ]; then
        run "rm -f '$TARGET'"
        note "removed ${TARGET}"
    else
        note "nothing to remove at ${TARGET}"
    fi
    exit 0
}

# Print, and optionally add, the PATH line - only when BIN_DIR is not already
# reachable. Idempotent: the line is added once.
handle_path() {
    case ":${PATH}:" in
        *":${BIN_DIR}:"*)
            note "${BIN_DIR} is already on PATH"
            return ;;
    esac

    line="export PATH=\"${BIN_DIR}:\$PATH\""
    rc=""
    case "$(basename "${SHELL:-/bin/sh}")" in
        zsh)  rc="${HOME}/.zshrc" ;;
        bash) if [ "$(uname -s)" = "Darwin" ]; then rc="${HOME}/.bash_profile"; else rc="${HOME}/.bashrc"; fi ;;
        *)    rc="${HOME}/.profile" ;;
    esac

    if [ "$MODIFY_PATH" -eq 0 ]; then
        note ""
        note "NOTE: ${BIN_DIR} is not on your PATH. Add this line to ${rc}:"
        note "    ${line}"
        return
    fi

    if [ -f "$rc" ] && grep -Fq "${BIN_DIR}" "$rc" 2>/dev/null; then
        note "PATH entry for ${BIN_DIR} already present in ${rc}"
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            printf 'dry-run: would append PATH line to %s\n' "$rc"
        else
            printf '\n# added by hdl-toolchain installer\n%s\n' "$line" >> "$rc" \
                || die "cannot write ${rc}"
            note "added ${BIN_DIR} to PATH in ${rc}"
        fi
    fi
    note ""
    note "Open a new terminal, or run:  ${line}"
}

main() {
    [ "$ACTION" = "uninstall" ] && uninstall
    preflight

    tmp="$(mktemp "${TMPDIR:-/tmp}/hdl-toolchain.XXXXXX")" || die "cannot create a temp file"
    trap 'rm -f "$tmp"' EXIT INT TERM

    if [ -n "${HDL_TOOLCHAIN_PAYLOAD_FILE:-}" ]; then
        # test hook: the digest is still verified, so this cannot smuggle an
        # unchecked payload past the check.
        cp "$HDL_TOOLCHAIN_PAYLOAD_FILE" "$tmp" || die "cannot read ${HDL_TOOLCHAIN_PAYLOAD_FILE}"
    else
        url="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
        note "downloading ${ASSET} ${VERSION}"
        fetch "$url" "$tmp" || die "download failed: ${url}"
    fi

    got="$(sha_of "$tmp")"
    if [ "$got" != "$SHA256" ]; then
        printf 'error: SHA-256 mismatch, refusing to install\n  expected: %s\n  got:      %s\n' \
            "$SHA256" "$got" >&2
        exit 1
    fi

    if [ -x "$TARGET" ] && [ "$(sha_of "$TARGET")" = "$SHA256" ]; then
        note "already at ${VERSION} - ${TARGET} is up to date"
        handle_path
        exit 0
    fi

    run "mkdir -p '$BIN_DIR'" || die "cannot create ${BIN_DIR}"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'dry-run: would install %s (%s)\n' "$TARGET" "$VERSION"
    else
        # install(1) is in stock macOS and Linux; chmod fallback for oddities.
        install -m 755 "$tmp" "$TARGET" 2>/dev/null \
            || { cp "$tmp" "$TARGET" && chmod 755 "$TARGET"; } \
            || die "cannot write ${TARGET}"
        note "installed ${TARGET} (${VERSION})"
    fi

    handle_path

    note ""
    note "Try it:  hdl-toolchain --version"
    note "Then:    hdl-toolchain --workspace . -- zsh -l"
}

main
