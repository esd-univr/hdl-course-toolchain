#!/usr/bin/env bash
# Cut a toolchain release.
#
#   scripts/release.sh vX.Y.Z
#
# This script does the *git* half only. It verifies the tree is releasable,
# pins the version into VERSION, bin/hdl-toolchain and install.sh, commits,
# creates an annotated tag, and pushes. Pushing the tag triggers
# .github/workflows/release.yml, which builds the qualified OCI image from the
# tagged source, pushes ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z and
# :latest, and publishes the GitHub Release with install.sh, hdl-toolchain and
# SHA256SUMS attached.
#
# It deliberately refuses to touch anything that already exists: an existing
# tag, an existing GitHub release, or an image tag already in GHCR.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${root}"

fail() { echo "release: $*" >&2; exit 1; }

version="${1:-}"
case "${version}" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "usage: scripts/release.sh vX.Y.Z" ;;
esac
bare="${version#v}"

# --- preconditions --------------------------------------------------------
[ -z "$(git status --porcelain)" ] || fail "working tree is dirty"
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "${branch}" = "main" ] || fail "not on main (on ${branch})"

git fetch --tags --quiet origin || true
if git rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
    fail "tag ${version} already exists locally — releases are never re-cut"
fi
if git ls-remote --exit-code --tags origin "refs/tags/${version}" >/dev/null 2>&1; then
    fail "tag ${version} already exists on origin"
fi

if command -v gh >/dev/null 2>&1; then
    if gh release view "${version}" >/dev/null 2>&1; then
        fail "a GitHub release ${version} already exists"
    fi
fi

# GHCR immutability: the versioned image tag must not already be published.
img="ghcr.io/esd-univr/hdl-course-toolchain:${version}"
if command -v docker >/dev/null 2>&1 && docker manifest inspect "${img}" >/dev/null 2>&1; then
    fail "${img} is already in GHCR — pick the next version"
fi

# --- local checks --------------------------------------------------------
echo "==> repository checks"
make --no-print-directory check
echo "==> launcher tests"
bash scripts/test_hdl_toolchain.sh
echo "==> installer tests"
bash scripts/test_install.sh

echo
echo "Have you run 'make qualify' on the tagged toolchain and recorded the"
echo "evidence in the release notes you are about to write? [y/N]"
read -r answer
case "${answer}" in [yY]|[yY][eE][sS]) ;; *) fail "qualify first, then re-run" ;; esac

# --- pin the version ----------------------------------------------------
printf '%s\n' "${bare}" > VERSION
sed -i.bak "s/^LAUNCHER_VERSION=\".*\"\$/LAUNCHER_VERSION=\"${bare}\"/" bin/hdl-toolchain
sed -i.bak "s/^VERSION=\".*\"\$/VERSION=\"${version}\"/" install.sh
sed -i.bak "s/^VERSION=\".*\"\$/VERSION=\"${version}\"/" uninstall.sh
rm -f bin/hdl-toolchain.bak install.sh.bak uninstall.sh.bak
./scripts/sync-installer-digest.sh

grep -q "^LAUNCHER_VERSION=\"${bare}\"\$" bin/hdl-toolchain || fail "could not pin the launcher version"
grep -q "^VERSION=\"${version}\"\$" install.sh || fail "could not pin the installer version"
grep -q "^VERSION=\"${version}\"\$" uninstall.sh || fail "could not pin the uninstaller version"

echo "==> re-running tests with the pinned version"
bash scripts/test_hdl_toolchain.sh
bash scripts/test_install.sh

# --- commit, tag, push ------------------------------------------------
git add VERSION bin/hdl-toolchain install.sh uninstall.sh
git commit -m "release: ${version}"
git tag -a "${version}" -m "hdl-course-toolchain ${version}"

echo
echo "About to push main and ${version} to origin. This triggers the release"
echo "workflow (image build + GHCR push + GitHub Release). Continue? [y/N]"
read -r answer
case "${answer}" in
    [yY]|[yY][eE][sS])
        git push origin main --follow-tags
        echo "pushed. Watch the release workflow:"
        echo "  gh run watch \$(gh run list --workflow=release.yml -L1 --json databaseId --jq '.[0].databaseId')"
        ;;
    *)
        echo "not pushed. The commit and tag exist locally; 'git push origin main --follow-tags' when ready,"
        echo "or 'git tag -d ${version} && git reset --hard HEAD~1' to undo."
        ;;
esac
