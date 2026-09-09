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
    python3 -c 'import json,sys;print(json.load(open(".out/publish.json")).get(sys.argv[1]) or "")' "$1" 2>/dev/null || true
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
    local ref record_id image_id live_digest ledger_digest remote_id
    ref="$(ghcr_ref "${VERSION}")"
    record_id="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field docker_image_id)"
    image_id="$(docker image inspect --format '{{.Id}}' \
        "$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field docker_image_ref)")"

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

main() {
    publish_validate
    require_tooling
    echo "publish: validation OK — ${VERSION} @ $(git rev-parse --short HEAD) (${PLATFORM})"
    publish_versioned_image
    # ---------------------------------------------------------------------
    # Tasks 10–12 continue below this line, all AFTER the gate above:
    #   10 — retag / push ${IMAGE_BASE}:latest
    #   11 — git tag ${VERSION} + push
    #   12 — gh release create ${VERSION}
    # ---------------------------------------------------------------------
}

main "$@"
