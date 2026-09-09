# Releasing the toolchain

## 1. What a release publishes

A release `vX.Y.Z` publishes three things:

| Artifact | Where | Mutable? |
|---|---|---|
| `ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z` | GHCR | **never** rewritten |
| `ghcr.io/esd-univr/hdl-course-toolchain:latest` | GHCR | moves only on a new qualified release |
| GitHub Release `vX.Y.Z` with `hdl-toolchain`, `install.sh`, `uninstall.sh`, `SHA256SUMS` | Releases page | never re-cut |

`SHA256SUMS` contains `sha256sum` lines for `hdl-toolchain`, `install.sh` and
`uninstall.sh` only — it does not checksum itself.

Students consume `:latest` through the installed `hdl-toolchain` launcher and
never clone this repository. Courses pin `…:vX.Y.Z@sha256:…` for reproducible
qualification.

`toolchain-release qualification` (this document) is **not** the same as
`course/lesson qualification`, which each course repository owns. Publishing the
image qualifies no course.

## 2. Three roles

```
GitHub Actions           = lightweight repository CI only (make check, make test, shellcheck)
maintainer workstation   = heavy toolchain build + qualification + OCI/Release publication
GitHub / GHCR            = distribution
```

Pushing a tag does **not** trigger an image build. The repository has a single
workflow, `check.yml`, which runs the same fast checks a contributor runs
locally. Every heavyweight step — the OCI build, `toolchain-doctor`, the GHCR
push, the GitHub Release — runs on the maintainer workstation, driven by
`make`.

## 3. One-time GHCR authentication

Pushing to `ghcr.io/esd-univr/hdl-course-toolchain` needs a token with the
`write:packages` scope. The default `gh` token has `repo` + `workflow` but
**not** `packages`, so this is a one-time setup on the maintainer workstation:

```bash
gh auth refresh -s write:packages,read:packages
gh auth token | docker login ghcr.io -u <github-user> --password-stdin
```

`make publish` never manipulates credentials. If the `:vX.Y.Z` push is rejected
for authorization, it stops cleanly and prints exactly these two commands. The
resumable design (§6) makes a mid-push auth failure safe to recover from: fix
the auth, re-run `make publish VERSION=vX.Y.Z`.

## 4. The flow

```bash
git switch main && git pull

make prepare VERSION=vX.Y.Z    # pins the version + commits "release: vX.Y.Z"; nothing else
make qualify                   # builds the image, runs both doctors, writes .out/qualification.json
make publish VERSION=vX.Y.Z    # validates the record, pushes :vX.Y.Z, moves :latest, tags, cuts the Release
```

### `make prepare VERSION=vX.Y.Z`

Preconditions (any failure aborts, the tree is left untouched):

- `VERSION` argument matches `v[0-9]+.[0-9]+.[0-9]+`;
- current branch is `main`;
- working tree clean;
- `git fetch origin` succeeds and `git rev-parse HEAD` == `git rev-parse
  origin/main` **exactly** — a release is never prepared from unpublished local
  commits, so a locally-ahead or diverged `main` aborts;
- the version is unused: no local tag, no origin tag, no GitHub Release, no GHCR
  `:vX.Y.Z` image;
- `install.sh` currently carries the dev sentinel `VERSION="v0.0.0-dev"`.

Actions: pin `VERSION` (bare `X.Y.Z`), `bin/hdl-toolchain`
(`LAUNCHER_VERSION="X.Y.Z"`), `install.sh` / `uninstall.sh`
(`VERSION="vX.Y.Z"`), re-sync the installer's launcher digest, run `make check`
and `make test` against the pinned tree, then `git commit -m "release:
vX.Y.Z"`. It never creates or pushes a tag, a Release or a GHCR image.

**Idempotent resume:** re-running `make prepare VERSION=vX.Y.Z` when HEAD is
already the matching `release: vX.Y.Z` commit (clean tree, HEAD's parent is
`origin/main`, all four files pinned consistently, the version still unused
everywhere) reports "already prepared at HEAD `<sha>`" and exits 0. Any other
divergence from `origin/main` aborts.

### `make qualify`

The five stages are unchanged: repository checks → OCI image build → Docker
`toolchain-doctor` → Apptainer SIF build → Apptainer `toolchain-doctor`, in
order, followed by the printed evidence block.

Around them:

1. **First**, `rm -f .out/qualification.json .out/publish.json` — no stale
   "passed" record and no ledger from an earlier release survive a re-run.
2. **Then**, before building, require `git status --porcelain` to be empty. A
   dirty tree would let uncommitted changes reach the image while
   `source_commit` still names the old HEAD, so `qualify` aborts on it.
3. Run the five stages.
4. **Only if all five passed and the tree is still clean**, write
   `.out/qualification.json` (§5).

`make qualify` does not depend on GitHub, GHCR or an already-published image,
and is not run as part of `prepare` or `publish` — it is the deliberate,
human-run gate. It is not strictly network-free: `make build` depends on `make
fetch`, so if the pinned source archives are not already cached under
`.out/sources/`, fetching them needs network access.

### `make publish VERSION=vX.Y.Z`

Never calls `docker build` / `make build` / `make fetch`. It validates the
record (§5), then publishes in this order, each step resumable (§6):

1. push `:vX.Y.Z` from the qualified local image (`docker tag <image_id>` then
   `docker push`);
2. read back and record the immutable registry digest;
3. move `:latest` — only now;
4. verify `:vX.Y.Z` and `:latest` resolve to the same digest;
5. create the annotated git tag `vX.Y.Z` on the qualified `source_commit`, then
   push it to origin;
6. assemble `SHA256SUMS`, then `gh release create vX.Y.Z --verify-tag` with the
   four assets and generated notes.

`make publish` publishes the release artifacts only. It does **not** advance
`main` or reset the tree for the next dev cycle — do that yourself once the
Release is live (the success summary reprints these):

```bash
git push origin main          # the "release: vX.Y.Z" commit is local-only until now

# hand the tree back to the dev sentinel so the next `make prepare` can run
sed -i 's/^VERSION=.*/VERSION="v0.0.0-dev"/' install.sh uninstall.sh
./scripts/sync-installer-digest.sh
git commit -am "chore: back to the dev sentinel after vX.Y.Z"
git push origin main
```

`make prepare` requires `install.sh` at `VERSION="v0.0.0-dev"` and `HEAD ==
origin/main` exactly, so skipping this blocks the next release with a sentinel
or sync error.

## 5. The qualification record

`.out/qualification.json` (schema 1, `status: "passed"`) is written only by
`make qualify`, only on full success. It binds the qualified image to the tree:

| Field | Meaning |
|---|---|
| `docker_image_id` | `docker image inspect --format '{{.Id}}'` — the content-addressable image ID, the **exact** binding between qualification and publication. A matching `:latest` tag or `org.opencontainers.image.revision` label is never sufficient on its own. |
| `source_commit` | `git rev-parse HEAD` at qualify time |
| `version` | the `VERSION` file, normalised to `vX.Y.Z` |
| `build_inputs_sha256` | `scripts/artifact-status.sh fingerprint docker` — over `versions.yml`, `Containerfile`, `requirements.txt`, `doctor/`, `container/` |
| `release_inputs_sha256` | sha256 over `VERSION`, `bin/hdl-toolchain`, `install.sh`, `uninstall.sh` |

`make publish` aborts, before any registry or git write, if any of these does
not hold:

| Check | Abort reason |
|---|---|
| record exists, `schema == 1`, `status == "passed"` | no successful qualification on record — run `make qualify` |
| record `version` == `VERSION=` argument | qualification is for a different version |
| record `version` == `VERSION` file now | `VERSION` file changed since qualification |
| record `source_commit` == `git rev-parse HEAD` now | HEAD moved since qualification — re-qualify |
| tree clean now | working tree dirty — re-qualify |
| `build_inputs_sha256` recomputed now == record | build inputs changed since qualification — re-qualify |
| `release_inputs_sha256` recomputed now == record | launcher/installer changed since qualification — re-qualify |
| local `docker_image_ref` exists and its `.Id` == record `docker_image_id` | local image is not the one qualification recorded — re-qualify |

`make publish` also checks that `docker` and `gh` are present and
authenticated. It does **not** create throwaway registry artifacts to probe
package-write permission — the first real registry write is the `:vX.Y.Z` push.

## 6. Resuming a failed publish

`make publish` writes `.out/publish.json` incrementally as each step completes:

```json
{
  "version": "vX.Y.Z",
  "source_commit": "<same as qualification>",
  "image_digest": "sha256:<immutable digest of :vX.Y.Z>",
  "versioned_ref": "ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z",
  "latest_moved": false,
  "tag_published": false,
  "release_created": false,
  "updated_at": "<UTC ISO-8601>"
}
```

For every resource, `publish` distinguishes three states:

| State | Behaviour |
|---|---|
| absent | create it |
| exists and matches this qualified release | report it, continue |
| exists and conflicts | **ABORT** — never mutate an immutable resource |

- **Versioned GHCR image** — absent → push. Exists → it must be *proven* to be
  the exact locally qualified image: if the ledger records an `image_digest`
  equal to the live `:vX.Y.Z` digest → continue; otherwise pull `:vX.Y.Z` for
  the qualified platform and compare the pulled image's `.Id` against the
  record's `docker_image_id`. If it matches → continue; if it differs → ABORT
  (`:vX.Y.Z` is immutable); if it cannot be pulled/inspected → ABORT rather than
  guess. (This assumes the image config digest survives a push/pull round-trip,
  which holds for the classic Docker image store. If a resume ever aborts here
  with "different image" for a `:vX.Y.Z` you know you published, verify the
  registry digest by hand against `.out/publish.json` before re-cutting.)
- **`:latest`** — moved only after `:vX.Y.Z` is confirmed present; skipped if
  `:latest` already resolves to `image_digest`.
- **Git tag** — absent → create + push. Points at `source_commit` → continue.
  Points elsewhere → ABORT.
- **GitHub Release** — absent → create. Exists on tag `vX.Y.Z` → continue.
  Targets a different tag → ABORT. Never blind-overwrite.

Worked example: `:vX.Y.Z` pushed, then the `:latest` push failed and no tag or
Release exists yet. Just re-run `make publish VERSION=vX.Y.Z` — it sees
`:vX.Y.Z` matches the ledger, skips it, and continues from `:latest`.

## 7. Choosing the version

```bash
git tag -l                     # what exists
cat VERSION                    # what the tree currently claims
gh release list --repo esd-univr/hdl-course-toolchain
```

Semantic intent:

- **patch** `vX.Y.Z+1` — packaging or launcher fix, identical tool set.
- **minor** `vX.Y+1.0` — tool version bumps, new tools, additive launcher/installer capability.
- **major** `vX+1.0.0` — a change consumers must react to (image namespace, launcher contract, dropped engine).

Never reuse a tag for different content. `v1.0.0`, `v1.1.0`, `v1.2.0` are spent.
`v1.3.x` is the GHCR-image + installer distribution model; nothing was ever
published for `v1.3.0`.

## 8. Verify the public path from scratch

```bash
# a throwaway HOME, nothing from this checkout on PATH
tmp="$(mktemp -d)"
env -i HOME="$tmp" PATH=/usr/bin:/bin SHELL=/bin/bash \
    sh -c 'curl -fsSL https://github.com/esd-univr/hdl-course-toolchain/releases/latest/download/install.sh | sh'
"$tmp/.local/bin/hdl-toolchain" --version
"$tmp/.local/bin/hdl-toolchain" --workspace "$tmp" -- toolchain-doctor
```

The launcher should pull `ghcr.io/esd-univr/hdl-course-toolchain:latest`, print
the digest `make publish` recorded, and the doctor should pass.

Cross-check the digest against the record and the Release notes:

```bash
python3 -c 'import json; d=json.load(open(".out/publish.json")); print(d["image_digest"])'
gh release view vX.Y.Z --json body --jq .body | grep sha256
docker buildx imagetools inspect ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z
```

## 9. Adopt it in the courses (separate, per course)

A course moves to the new toolchain only after **that course's** own
qualification passes against `…:vX.Y.Z@sha256:…`. That work lives in the course
repository (`toolchain-baseline.yml`, `make qualify`), not here.
