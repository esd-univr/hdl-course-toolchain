#!/usr/bin/env bash
# Phase 3 of a release: publish the already-qualified local image. NEVER builds.
# Resumable — safe to re-run after a network failure. See docs/releasing.md.
#
#   scripts/publish-release.sh vX.Y.Z
#
# This script publishes the *exact* image that `make qualify` locally qualified.
# It runs a validation gate first: every check below must pass before any
# network / registry / git write happens. It NEVER runs `docker build` /
# `make build` / `make fetch` — if there is no valid qualification record for
# the current tree it fails closed.
set -euo pipefail

_DIR="$(cd "$(dirname "$0")" && pwd)"
_ROOT="$(dirname "${_DIR}")"
# shellcheck source=scripts/release_lib.sh
. "${_DIR}/release_lib.sh"
cd "${_ROOT}"

VERSION="${1:-}"
case "${VERSION}" in
    v[0-9]*.[0-9]*.[0-9]*) : ;;
    *) die "usage: scripts/publish-release.sh vX.Y.Z" ;;
esac

RECORD=".out/qualification.json"
LEDGER=".out/publish.json"
# PLATFORM comes from the record so a later push targets exactly the qualified
# platform; fall back to the default when the record is absent (the gate then
# aborts anyway).
PLATFORM="$(python3 -c 'import json;print(json.load(open(".out/qualification.json"))["platform"])' 2>/dev/null || echo "${PLATFORM_DEFAULT}")"
export PLATFORM

# --- validation gate --------------------------------------------------------
# Confirm the qualification record still describes the current tree, the current
# HEAD and the local Docker image. The binding identity is docker_image_id
# (sha256:…) — a matching :latest tag or revision label is never sufficient.
# All of version / version-file / head / tree-clean / both fingerprints /
# image-id are compared by one `qualification.py verify` call.
publish_validate() {
    [ -f "${RECORD}" ] \
        || die "no qualification record (${RECORD}) — run 'make qualify' first"

    local rec_ref image_id tree_clean
    rec_ref="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field docker_image_ref)" \
        || die "qualification record (${RECORD}) is missing or unreadable — run 'make qualify'"

    image_id="$(docker image inspect --format '{{.Id}}' "${rec_ref}" 2>/dev/null)" \
        || die "the qualified image ${rec_ref} is not present locally — run 'make qualify'"
    [ -n "${image_id}" ] \
        || die "the qualified image ${rec_ref} is not present locally — run 'make qualify'"

    tree_clean=1
    [ -z "$(git status --porcelain)" ] || tree_clean=0

    python3 "${_DIR}/qualification.py" verify \
        --record "${RECORD}" \
        --version "${VERSION}" \
        --version-file "$(cat VERSION)" \
        --head "$(git rev-parse HEAD)" \
        --tree-clean "${tree_clean}" \
        --build-inputs-sha256 "$(build_inputs_fingerprint)" \
        --release-inputs-sha256 "$(release_inputs_fingerprint)" \
        --image-id "${image_id}" \
        || die "qualification does not match the current tree / HEAD / image — re-run 'make qualify' on this commit"
}

# --- tooling / auth check --------------------------------------------------
# docker + gh must be present, docker usable, gh authenticated. This does not
# write anything: package-write permission is proven by the first real push
# (the :vX.Y.Z tag), added in a later task — the spec forbids probing it with a
# throwaway artifact.
require_tooling() {
    command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
    command -v gh     >/dev/null 2>&1 || die "gh not found on PATH — https://cli.github.com"
    docker info >/dev/null 2>&1       || die "docker is not running / not usable"
    gh auth status >/dev/null 2>&1    || die "gh is not authenticated — run: gh auth login"
}

# --- ledger (.out/publish.json) ------------------------------------------
# The resumable record of what this release has already published. JSON handling
# stays in Python so shell never parses or emits JSON.
ledger_init() {
    python3 - "$@" <<'PY'
import json, sys, datetime
version, commit, ref = sys.argv[1:4]
json.dump({
    "version": version, "source_commit": commit,
    "image_digest": None, "versioned_ref": ref,
    "latest_moved": False, "tag_published": False, "release_created": False,
    "updated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, open(".out/publish.json", "w"), indent=2, sort_keys=True)
PY
}

ledger_get() {
    # Return the ledger value verbatim: "" only when the key is absent or null,
    # "true"/"false" for a JSON boolean (never collapse False to ""), the string
    # otherwise.
    python3 - "$1" <<'PY' 2>/dev/null || true
import json, sys
v = json.load(open(".out/publish.json")).get(sys.argv[1])
if v is None:
    print("")
elif v is True:
    print("true")
elif v is False:
    print("false")
else:
    print(v)
PY
}

ledger_set() {
    python3 - "$1" "$2" <<'PY'
import json, sys, datetime
key, val = sys.argv[1], sys.argv[2]
p = ".out/publish.json"
d = json.load(open(p))
if val in ("true", "false"):
    d[key] = (val == "true")
else:
    d[key] = val
d["updated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
}

# --- step 1: publish the versioned image --------------------------------
# Push ${IMAGE_BASE}:${VERSION} from the qualified local image, resumably.
# The versioned tag is IMMUTABLE: if it already exists with a different image
# this is a hard error, never an overwrite. Binding identity is the record's
# docker_image_id — the revision label is never the sole check.
publish_versioned_image() {
    local ref record_id rec_ref image_id live_digest ledger_digest remote_id
    ref="$(ghcr_ref "${VERSION}")"
    record_id="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field docker_image_id)" \
        || die "qualification record unreadable (docker_image_id) — run 'make qualify'"
    rec_ref="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field docker_image_ref)" \
        || die "qualification record unreadable (docker_image_ref) — run 'make qualify'"
    image_id="$(docker image inspect --format '{{.Id}}' "${rec_ref}")" \
        || die "the qualified image ${rec_ref} is not present locally — run 'make qualify'"

    [ -f "${LEDGER}" ] || ledger_init "${VERSION}" "$(git rev-parse HEAD)" "${ref}"
    ledger_digest="$(ledger_get image_digest)"

    if live_digest="$(ghcr_manifest_digest "${VERSION}" 2>/dev/null)"; then
        if [ -n "${ledger_digest}" ] && [ "${ledger_digest}" = "${live_digest}" ]; then
            echo "publish: ${ref} already published (${live_digest})"
            return 0
        fi
        # The tag exists but the ledger cannot vouch for it — PROVE the remote
        # image is the qualified one by pulling it and comparing its image id.
        if ! remote_id="$(remote_image_id "${VERSION}" "${PLATFORM}")"; then
            die "${ref} already exists but cannot be pulled/inspected — cannot prove the published :${VERSION} is the qualified image"
        fi
        [ "${remote_id}" = "${record_id}" ] \
            || die "${ref} already exists with a different image (${remote_id} != ${record_id}) — versioned releases are immutable"
        echo "publish: ${ref} already published and matches the qualified image"
        ledger_set image_digest "${live_digest}"
        return 0
    fi

    echo "publish: pushing ${ref}"
    docker tag "${image_id}" "${ref}"
    if ! docker push "${ref}"; then
        die "push to ${ref} failed. If this is an authorization error, GHCR needs a token with package-write scope:
  gh auth refresh -s write:packages
  gh auth token | docker login ghcr.io -u <github-user> --password-stdin
then re-run: make publish VERSION=${VERSION}"
    fi
    live_digest="$(ghcr_manifest_digest "${VERSION}")" \
        || die "pushed ${ref} but cannot read its manifest digest back"
    ledger_set image_digest "${live_digest}"
    echo "publish: published ${ref} @ ${live_digest}"
}

# --- step 2: move :latest onto the published release --------------------
# Retag ${IMAGE_BASE}:latest to the image just published as ${IMAGE_BASE}:${VERSION}
# and push it — but ONLY after the versioned image is confirmed published
# (ledger image_digest set). The versioned tag is the durable identity; :latest
# is a moving pointer, so it moves last and is re-probed afterwards to prove it
# resolves to the exact same digest.
publish_move_latest() {
    local digest latest_ref live
    digest="$(ledger_get image_digest)"
    [ -n "${digest}" ] \
        || die "internal: move_latest called before the versioned image was published"
    latest_ref="${IMAGE_BASE}:latest"

    if live="$(ghcr_manifest_digest latest 2>/dev/null)" && [ "${live}" = "${digest}" ]; then
        echo "publish: ${latest_ref} already at ${digest}"
        ledger_set latest_moved true
        return 0
    fi

    echo "publish: moving ${latest_ref} to this release"
    docker tag "$(ghcr_ref "${VERSION}")" "${latest_ref}"
    docker push "${latest_ref}" \
        || die "push to ${latest_ref} failed — re-run: make publish VERSION=${VERSION}"
    live="$(ghcr_manifest_digest latest 2>/dev/null || true)"
    [ "${live}" = "${digest}" ] \
        || die "${latest_ref} resolved to ${live}, expected ${digest}"
    ledger_set latest_moved true
    echo "publish: ${latest_ref} -> ${digest}"
}

# --- step 3: annotated git tag on the qualified commit -----------------
# Create the annotated tag ${VERSION} ON THE QUALIFIED source_commit (from the
# record, not necessarily HEAD), locally then on origin — resumably. A tag that
# already exists on the wrong commit is a hard error, never a move.
publish_tag() {
    local want local_sha origin_sha
    want="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field source_commit)" \
        || die "qualification record unreadable (source_commit) — run 'make qualify'"

    if local_sha="$(git rev-parse -q --verify "refs/tags/${VERSION}^{commit}" 2>/dev/null)"; then
        [ "${local_sha}" = "${want}" ] \
            || die "local tag ${VERSION} points at ${local_sha}, not the qualified commit ${want}"
    else
        echo "publish: creating annotated tag ${VERSION}"
        git tag -a "${VERSION}" -m "hdl-course-toolchain ${VERSION}" "${want}"
    fi

    if origin_sha="$(origin_tag_object_sha "${VERSION}" 2>/dev/null)" && [ -n "${origin_sha}" ]; then
        [ "${origin_sha}" = "${want}" ] \
            || die "origin tag ${VERSION} points at ${origin_sha}, not ${want}"
        echo "publish: origin already has ${VERSION}"
    else
        echo "publish: pushing tag ${VERSION} to origin"
        git push origin "refs/tags/${VERSION}" \
            || die "could not push tag ${VERSION} to origin — push it manually, then re-run make publish"
    fi
    ledger_set tag_published true
}

# --- step 4: release notes (.out/dist/NOTES.md) ------------------------
# Human-readable notes for the GitHub Release. Records the immutable identity of
# what was published: source commit, architecture, the :vX.Y.Z ref and its
# @sha256 digest (from the ledger), the fact that :latest was moved here, and a
# qualification summary (both doctor verdicts, the build-input fingerprint and
# when it was qualified).
publish_release_notes() {
    local digest arch commit binfp qat dd da
    digest="$(ledger_get image_digest)"
    arch="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field architecture)"
    commit="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field source_commit)"
    binfp="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field build_inputs_sha256)"
    qat="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field qualified_at)"
    dd="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field doctor_docker)"
    da="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field doctor_apptainer)"
    mkdir -p .out/dist
    cat > .out/dist/NOTES.md <<EOF
## hdl-course-toolchain ${VERSION}

### Official image
\`\`\`
docker pull $(ghcr_ref "${VERSION}")
$(ghcr_ref "${VERSION}")@${digest}
\`\`\`
\`${IMAGE_BASE}:latest\` was moved to this release.

### Student install (one time)
\`\`\`
curl -fsSL https://github.com/${REPO}/releases/latest/download/install.sh | bash
\`\`\`

### Qualification
| | |
|---|---|
| source commit | \`${commit}\` |
| architecture | ${arch} |
| Docker doctor | ${dd} |
| Apptainer doctor | ${da} |
| build-input fingerprint | \`${binfp}\` |
| qualified at | ${qat} |
EOF
}

# --- step 5: the GitHub Release ---------------------------------------
# Assemble .out/dist/ (the launcher, the installer/uninstaller and a SHA256SUMS
# over exactly those three — SHA256SUMS never checksums itself) and create the
# Release, resumably. An existing Release on the target tag is left untouched; one
# on a different tag is a hard error — this never blind-overwrites a Release.
publish_github_release() {
    mkdir -p .out/dist
    cp bin/hdl-toolchain .out/dist/hdl-toolchain
    cp install.sh .out/dist/install.sh
    cp uninstall.sh .out/dist/uninstall.sh
    ( cd .out/dist && sha256sum hdl-toolchain install.sh uninstall.sh > SHA256SUMS )
    publish_release_notes

    if gh release view "${VERSION}" >/dev/null 2>&1; then
        local tn
        tn="$(gh release view "${VERSION}" --json tagName --jq .tagName 2>/dev/null || true)"
        [ "${tn}" = "${VERSION}" ] \
            || die "a GitHub Release ${VERSION} exists but is on tag '${tn}' — refusing to touch it"
        echo "publish: GitHub Release ${VERSION} already created — leaving it as-is"
    else
        echo "publish: creating GitHub Release ${VERSION}"
        gh release create "${VERSION}" \
            .out/dist/hdl-toolchain .out/dist/install.sh .out/dist/uninstall.sh .out/dist/SHA256SUMS \
            --title "hdl-course-toolchain ${VERSION}" \
            --notes-file .out/dist/NOTES.md \
            --verify-tag \
            || die "gh release create failed — fix the cause and re-run make publish VERSION=${VERSION}"
    fi
    ledger_set release_created true
    echo
    echo "publish: ${VERSION} is live"
    gh release view "${VERSION}" --json url --jq .url 2>/dev/null || true
}

main() {
    publish_validate
    require_tooling
    echo "publish: validation OK — ${VERSION} @ $(git rev-parse --short HEAD) (${PLATFORM})"
    publish_versioned_image
    publish_move_latest
    publish_tag
    publish_github_release

    echo
    echo "publish: ${VERSION} summary"
    echo "  image digest:    $(ledger_get image_digest)"
    echo "  :latest moved:   $(ledger_get latest_moved)"
    echo "  tag published:   $(ledger_get tag_published)"
    echo "  release created: $(ledger_get release_created)"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
