#!/bin/sh
#
# uninstall.sh - remove the hdl-toolchain launcher
#                (https://github.com/esd-univr/hdl-course-toolchain)
#
#   uninstall.sh                 remove ~/.local/bin/hdl-toolchain and nothing else
#   uninstall.sh --dry-run       show exactly what would be removed, change nothing
#   uninstall.sh --purge-image   also remove local Docker images that are exactly
#                                ghcr.io/esd-univr/hdl-course-toolchain (any tag)
#   uninstall.sh --version       print the version this script belongs to
#   uninstall.sh --help          this text
#
# Deliberately conservative. It never touches Docker itself, unrelated images or
# containers, lesson workspaces, student files, Docker's global cache, or your
# shell configuration. With --purge-image it removes images for this one exact
# repository only, and if a container is using one it reports and stops rather
# than forcing anything.
#
# POSIX sh, like install.sh: runs under the stock macOS /bin/sh.

set -u

# --- pinned by scripts/release.sh when a release is cut -------------------
VERSION="v1.3.1"
# ------------------------------------------------------------------------

IMAGE_REPO="ghcr.io/esd-univr/hdl-course-toolchain"
BIN_DIR="${HDL_TOOLCHAIN_BIN_DIR:-${HOME}/.local/bin}"
TARGET="${BIN_DIR}/hdl-toolchain"
DOCKER="${HDL_TOOLCHAIN_DOCKER:-docker}"

DRY_RUN=0
PURGE_IMAGE=0

note() { printf '%s\n' "$*"; }
act()  { if [ "$DRY_RUN" -eq 1 ]; then printf 'would run: %s\n' "$*"; else eval "$*"; fi; }

usage() {
    cat <<USAGE
hdl-toolchain uninstaller ${VERSION}

  uninstall.sh                 remove ${TARGET} and nothing else
  uninstall.sh --dry-run       show what would be removed, change nothing
  uninstall.sh --purge-image   also remove local Docker images that are exactly
                               ${IMAGE_REPO} (any tag)
  uninstall.sh --version       print the version this script belongs to
  uninstall.sh --help          this text

It never removes Docker itself, unrelated images or containers, lesson
workspaces, student files, Docker's cache, or your shell configuration.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY_RUN=1 ;;
        --purge-image)  PURGE_IMAGE=1 ;;
        --version)      printf '%s\n' "$VERSION"; exit 0 ;;
        -h|--help)      usage; exit 0 ;;
        *)              printf 'error: unknown option: %s (try --help)\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

[ "$DRY_RUN" -eq 1 ] && note "dry run: nothing will be changed"

# --- the launcher ------------------------------------------------------
removed_any=0
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    act "rm -f '$TARGET'"
    note "removed ${TARGET}"
    removed_any=1
else
    note "no launcher at ${TARGET}"
fi

# A PATH line the installer may have added is left alone on purpose; editing
# shell rc files automatically is riskier than the line is worth.
for rc in "${HOME}/.zshrc" "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.profile"; do
    if [ -f "$rc" ] && grep -Fq "# added by hdl-toolchain installer" "$rc" 2>/dev/null; then
        note "note: ${rc} still has the PATH line the installer added; remove it by hand if you want it gone:"
        note "      # added by hdl-toolchain installer"
        note "      export PATH=\"${BIN_DIR}:\$PATH\""
    fi
done

# --- optional: images for this exact repository ----------------------
if [ "$PURGE_IMAGE" -eq 1 ]; then
    if ! command -v "$DOCKER" >/dev/null 2>&1; then
        note "--purge-image: docker not found; nothing to purge"
    elif ! "$DOCKER" info >/dev/null 2>&1; then
        note "--purge-image: docker is not responding; not touching any images"
    else
        # Containers (running or stopped) whose image is this repo. Match the
        # repository prefix exactly, never a substring of some other name.
        in_use=$("$DOCKER" ps -a --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null \
            | while read -r cid cimg cname; do
                case "$cimg" in
                    "${IMAGE_REPO}"|"${IMAGE_REPO}:"*|"${IMAGE_REPO}@"*)
                        printf '  %s  %s  (%s)\n' "$cid" "$cimg" "$cname" ;;
                esac
              done)
        if [ -n "$in_use" ]; then
            note "--purge-image: these containers use ${IMAGE_REPO}; not removing anything:"
            printf '%s\n' "$in_use"
            note "remove those containers yourself first if you really want the images gone."
        else
            tags=$("$DOCKER" image ls "${IMAGE_REPO}" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
                   | grep -v '<none>' || true)
            ids=$("$DOCKER" image ls "${IMAGE_REPO}" --format '{{.ID}}' 2>/dev/null | sort -u || true)
            if [ -z "$tags" ] && [ -z "$ids" ]; then
                note "--purge-image: no local ${IMAGE_REPO} images"
            else
                for t in $tags; do
                    act "$DOCKER rmi $t"
                    removed_any=1
                done
                # Catch images left only by digest (no named tag).
                for i in $ids; do
                    if [ "$DRY_RUN" -eq 1 ]; then
                        "$DOCKER" image ls "${IMAGE_REPO}" --format '{{.ID}} {{.Repository}}:{{.Tag}}' \
                            | grep "^$i " | grep -q ':<none>' \
                            && printf 'would run: %s rmi %s\n' "$DOCKER" "$i"
                    else
                        "$DOCKER" image inspect "$i" >/dev/null 2>&1 && "$DOCKER" rmi "$i" >/dev/null 2>&1 \
                            && { note "removed image $i"; removed_any=1; }
                    fi
                done
                note "--purge-image: done (only ${IMAGE_REPO})"
            fi
        fi
    fi
else
    note "images left in place; pass --purge-image to also remove ${IMAGE_REPO} images"
fi

[ "$removed_any" -eq 1 ] || note "nothing to do"
exit 0
