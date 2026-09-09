# Local release machinery — design

**Date:** 2026-09-09
**Status:** approved (design), pending implementation
**Scope:** the release/publication subsystem only. The launcher
(`bin/hdl-toolchain`), `install.sh`, `uninstall.sh` architecture and the two
course repositories are out of scope and are not modified, except documentation
that describes the old publication procedure.

---

## 1. Problem

The tag-triggered GitHub Actions release build
(`.github/workflows/release.yml`) is not a viable way to build this OCI image.
Run `34219055168` (`v1.3.1`) passed the guards and the source fetch, then spent
~64 minutes in *Build OCI image* before the GitHub-hosted runner failed with
`System.IO.IOException: No space left on device`. The image compiles Verilator,
Yosys, OpenROAD, HARM and HIF from source; a disposable `ubuntu-latest` runner
is the wrong place to make a release depend on a full rebuild. This is not to be
solved with longer timeouts, cleanup hacks, or a bigger BuildKit cache.

## 2. Decision

OCI release builds and publication move to the **maintainer workstation**.
GitHub Actions keeps only lightweight CI (`make check`, `make test`,
shellcheck). The release must not rebuild the toolchain in CI.

**Core invariant:**

> The OCI image published to GHCR is the exact local image that was already
> built and passed `make qualify` on the maintainer workstation. Publication
> never rebuilds; it proves the local image is the qualified one, then pushes
> it.

```
tagged/release source
        |  make prepare  (pin version, commit "release: vX.Y.Z", nothing else)
        v
local HEAD == the exact commit to be released
        |  make qualify  (build + both doctors; writes .out/qualification.json)
        v
qualified local OCI image  +  machine-checkable record bound to this HEAD
        |  make publish   (NO rebuild; validate record, then push)
        v
ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z   (immutable)
ghcr.io/esd-univr/hdl-course-toolchain:latest    (moved only after :vX.Y.Z is safe)
GitHub Release vX.Y.Z  (hdl-toolchain, install.sh, uninstall.sh, SHA256SUMS)
```

## 3. Cleanup of the failed `v1.3.1` attempt (done first, on its own)

### 3.1 Inventory (verified 2026-09-09)

| Artifact | `v1.3.0` | `v1.3.1` |
|---|---|---|
| Local git tag | absent | **exists** → `6805fa1` (annotated, tag object `2ec4bd5`) |
| Origin git tag | absent (`git/ref/tags/v1.3.0` → 404) | **exists** → `refs/tags/v1.3.1` |
| GitHub Release | absent | absent (releases stop at `v1.2.0`) |
| GHCR image | absent (repo `NAME_UNKNOWN`) | absent (repo `NAME_UNKNOWN`) |

The GHCR repository `esd-univr/hdl-course-toolchain` does not exist at all: no
image was ever published at any version. `v1.3.1` was never published as a
release or an OCI artifact, so it remains the intended next version.

### 3.2 Actions

Only artifacts that actually exist are deleted. `v1.3.0` needs nothing.

1. `git branch backup/pre-cleanup-main` — safety net kept until the maintainer
   is satisfied.
2. `git tag -d v1.3.1` (local).
3. `gh api -X DELETE repos/esd-univr/hdl-course-toolchain/git/refs/tags/v1.3.1`
   (origin).
4. Reconstruct `main` without the two premature `release:` commits, keeping the
   three real commits between them:

   ```
   before:  cbfbdd0 - 30cb593(release: v1.3.0) - e6c122a - f977e9c - e26b192 - 6805fa1(release: v1.3.1)
   after:   cbfbdd0 - e6c122a' - f977e9c' - e26b192'
   ```

   via `git reset --hard cbfbdd0 && git cherry-pick e6c122a f977e9c e26b192`.
5. Verify the resulting tree is the intended honest unreleased state **before**
   touching origin:
   - `VERSION` = `1.3.0`
   - `bin/hdl-toolchain` `LAUNCHER_VERSION="1.3.0"`
   - `install.sh` / `uninstall.sh` `VERSION="v0.0.0-dev"` (the pre-existing
     between-releases sentinel)
   - `install.sh` `SHA256=` matches `sha256(bin/hdl-toolchain)` for that tree
     (`scripts/sync-installer-digest.sh --check`)
   - `make check` passes
6. Force-update `origin/main`
   (`gh api -X PATCH repos/.../git/refs/heads/main -f sha=<new> -F force=true`,
   or `git push --force origin main`).
7. The failed Actions run `34219055168` is left as historical evidence.

Implementation of the new machinery then proceeds on a branch
`feature/local-release-machinery`.

## 4. Phase structure

`scripts/release.sh` is removed and replaced by three focused scripts plus a
shared library:

| File | Role |
|---|---|
| `scripts/prepare-release.sh` | phase 1 — pin + commit |
| `scripts/qualification.sh` | shared — compute fingerprints, write/read/verify `.out/qualification.json` |
| `scripts/publish-release.sh` | phase 3 — validate + push (no build) |

Makefile targets:

| Target | Command | Notes |
|---|---|---|
| `prepare` | `make prepare VERSION=vX.Y.Z` | new |
| `qualify` | `make qualify` | existing 5 stages; now also writes the record |
| `publish` | `make publish VERSION=vX.Y.Z` | new; never runs `docker build` |
| `release` | — | removed; kept as an error stub printing the new flow |

### 4.1 `make prepare VERSION=vX.Y.Z`

**Preconditions** (any failure aborts, tree untouched). The idempotent-resume
check in the last bullet is evaluated first; if it matches, `prepare` reports
and exits 0 without re-checking the dev-sentinel precondition (which no longer
holds once a release is pinned).

- `VERSION` argument present and matches `v[0-9]+.[0-9]+.[0-9]+`.
- Current branch is `main`.
- Working tree clean (`git status --porcelain` empty).
- `git fetch origin` succeeds and `main` is not behind `origin/main`.
- Version unused, all four checked:
  - no local tag `vX.Y.Z`;
  - no origin tag (`gh api .../git/ref/tags/vX.Y.Z` → 404 expected);
  - no GitHub Release (`gh release view vX.Y.Z` → not found expected);
  - no GHCR image `ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z` (authenticated
    registry manifest probe → absent expected; if the probe cannot authenticate,
    abort asking the maintainer to `docker login ghcr.io`).
- Installer currently at the dev sentinel: `install.sh` `VERSION="v0.0.0-dev"`
  (guards against running `prepare` twice, or on a tree that already half-pins a
  release).

**Actions:**

1. `VERSION` file → `X.Y.Z`.
2. `bin/hdl-toolchain` → `LAUNCHER_VERSION="X.Y.Z"`.
3. `install.sh` → `VERSION="vX.Y.Z"`; `uninstall.sh` → `VERSION="vX.Y.Z"`.
4. `scripts/sync-installer-digest.sh` → rewrites `install.sh` `SHA256=` to
   `sha256(bin/hdl-toolchain)` after the launcher was version-pinned.
5. `make check` and `make test` (launcher + installer + uninstaller suites),
   run against the pinned tree.
6. `git add VERSION bin/hdl-toolchain install.sh uninstall.sh`
   `git commit -m "release: vX.Y.Z"`.

**Never:** create or push a tag, create a GitHub Release, or push anything to
GHCR.

**Idempotent resume:** if invoked again with the same `VERSION` while HEAD is
already `release: vX.Y.Z` for that version, the tree is clean, and the four
"unused" checks still pass, report "already prepared at HEAD `<sha>`" and exit
0.

After `prepare`, HEAD is the exact commit intended to become the release.

### 4.2 `make qualify` (extended)

Existing behaviour is unchanged: repository checks → OCI image build → Docker
`toolchain-doctor` → Apptainer SIF build → Apptainer `toolchain-doctor`, in
order, followed by the printed human evidence block.

**New:**

- At the very start, `rm -f .out/qualification.json` so a mid-run failure can
  never leave a stale "passed" record behind.
- As the final step, only when all five stages passed, write
  `.out/qualification.json` (schema in §5) via `scripts/qualification.sh`.
- The printed evidence block gains one line pointing at the JSON record.

`make qualify` still needs no network and is still the deliberate, human-run
gate. It is **not** run as part of `prepare` or `publish`.

### 4.3 `make publish VERSION=vX.Y.Z`

**Never calls `docker build`.** If `.out/qualification.json` is missing or
stale, it aborts and tells the maintainer to run `make qualify`.

**Validation gate** — every check must hold, else abort before any registry or
git write:

| Check | Failure message |
|---|---|
| `.out/qualification.json` exists, `schema == 1`, `status == "passed"` | "no successful qualification on record — run make qualify" |
| record `version` == `VERSION=` arg | "qualification is for `<v>`, not `<arg>`" |
| record `version` == `VERSION` file now | "VERSION file changed since qualification" |
| record `source_commit` == `git rev-parse HEAD` now | "HEAD moved since qualification — re-qualify" |
| tree clean now | "working tree dirty — re-qualify" |
| `build_inputs_sha256` recomputed now == record | "build inputs changed since qualification — re-qualify" |
| `release_inputs_sha256` recomputed now == record | "launcher/installer changed since qualification — re-qualify" |
| local image `docker_image_ref` exists and `docker image inspect --format '{{.Id}}'` == record `docker_image_id` | "local image is not the one qualification recorded — re-qualify" |

`build_inputs_sha256` is the existing `scripts/artifact-status.sh` docker
fingerprint (over `versions.yml`, `Containerfile`, `requirements.txt`,
`doctor/`, `container/`). `release_inputs_sha256` is a new fingerprint over
`VERSION`, `bin/hdl-toolchain`, `install.sh`, `uninstall.sh`.

**Auth check:** verify `docker` and `gh` are present and authenticated. Do
**not** create throwaway registry artifacts to test package-write permission.
The first legitimate registry write is the `:vX.Y.Z` push itself; if GHCR
rejects it for authorization, stop cleanly with:

> not authorized to push to ghcr.io/esd-univr/hdl-course-toolchain
> run: `gh auth refresh -s write:packages`
>   then: `gh auth token | docker login ghcr.io -u <user> --password-stdin`

The resumable design (§6) makes a mid-push auth failure safe to recover from.

**Publication order** (each step resumable per §6):

1. Push `ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z` from the qualified local
   image (`docker tag <image_id> ...:vX.Y.Z && docker push ...:vX.Y.Z`).
2. Read back and record the immutable registry digest.
3. Move `:latest` — only now: `docker tag ...:vX.Y.Z ...:latest && docker push
   ...:latest`.
4. Verify `:vX.Y.Z` and `:latest` resolve to the same digest.
5. Create the annotated git tag `vX.Y.Z` on the qualified `source_commit`
   (local), then publish it to origin.
6. Create the GitHub Release `vX.Y.Z` with assets `hdl-toolchain`, `install.sh`,
   `uninstall.sh`, `SHA256SUMS` and generated notes.

**Release notes** include: source commit; qualified architecture; official
versioned reference `ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z`; the
immutable `@sha256:` digest; a statement that `:latest` was moved to this
release; and the qualification summary (both doctor results, build-inputs
fingerprint, `qualified_at`).

## 5. `.out/qualification.json`

Schema 1. Written only by `make qualify`, only on full success.

```json
{
  "schema": 1,
  "status": "passed",
  "version": "vX.Y.Z",
  "source_commit": "<git rev-parse HEAD>",
  "source_tree_clean": true,
  "build_inputs_sha256": "<artifact-status.sh docker fingerprint>",
  "release_inputs_sha256": "<sha256 over VERSION, bin/hdl-toolchain, install.sh, uninstall.sh>",
  "docker_image_ref": "hdl-course-toolchain:latest",
  "docker_image_id": "sha256:<docker image inspect .Id>",
  "sif_path": ".out/hdl-course-toolchain.sif",
  "sif_sha256": "<sha256 of the SIF>",
  "platform": "linux/amd64",
  "architecture": "<uname -m>",
  "doctor_docker": "pass",
  "doctor_apptainer": "pass",
  "qualified_at": "<UTC ISO-8601>"
}
```

Notes:

- `version` is read from the `VERSION` file at qualify time and normalised to
  `vX.Y.Z`.
- `docker_image_id` is the content-addressable image ID, the exact binding
  between qualification and publication. Presence of a `hdl-course-toolchain:latest`
  tag is never sufficient on its own.
- JSON is emitted by a small Python helper (Python is already a hard
  dependency) to avoid hand-rolled shell quoting.

## 6. Resumable publication — `.out/publish.json`

A progress ledger written incrementally as `publish` completes each step:

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
| exists and conflicts | **ABORT** — never silently mutate an immutable resource |

Concretely:

- **Versioned GHCR image** — absent → push. Exists with the digest recorded in
  `.out/publish.json` (or, on a fresh ledger, exists with
  `org.opencontainers.image.revision` label == `source_commit`) → continue.
  Exists with a different digest → ABORT (versioned releases are immutable).
- **`:latest`** — moved only after `:vX.Y.Z` is confirmed present. If `:latest`
  already resolves to `image_digest` → continue.
- **Git tag** — absent → create/publish. Exists pointing at `source_commit` →
  continue. Points elsewhere → ABORT.
- **GitHub Release** — absent → create. Exists on tag `vX.Y.Z` and (if its body
  carries a digest) consistent with `image_digest` → continue. Exists targeting
  a different tag/commit → ABORT. Never blind-overwrite.

Result: after e.g. `:vX.Y.Z` succeeds but `:latest` push fails and no tag/release
exists yet, re-running `make publish VERSION=vX.Y.Z` safely continues from
`:latest`.

## 7. GHCR authentication (documented, not automated)

- `ghcr.io/esd-univr/hdl-course-toolchain` push needs a token with
  `write:packages`. The maintainer's current `gh` token has `repo` + `workflow`
  but **not** `packages`.
- One-time setup (documented in `docs/releasing.md`):

  ```bash
  gh auth refresh -s write:packages,read:packages
  gh auth token | docker login ghcr.io -u <github-user> --password-stdin
  ```

- `publish` never manipulates credentials. On an unauthorized push it stops and
  prints the commands above.

## 8. `:latest` policy (unchanged)

- `:vX.Y.Z` immutable, never rewritten.
- `:latest` is the moving student/default release, moved only after the
  versioned image for that release is successfully published.
- Students consume `ghcr.io/esd-univr/hdl-course-toolchain:latest` through the
  installed launcher. Course qualification may pin the resulting immutable
  `…:vX.Y.Z@sha256:…`.

## 9. GitHub Actions

- `.github/workflows/release.yml` is deleted in full.
- `.github/workflows/check.yml` is kept: on push / pull_request it runs
  `make check`, `shellcheck -S warning bin/hdl-toolchain install.sh uninstall.sh
  scripts/*.sh` (which now also covers the new release scripts), and `make
  test`.
- No workflow triggers on tags. No workflow runs `make build`, `make fetch`, or
  any GHCR / release step.

## 10. Documentation

| File | Change |
|---|---|
| `docs/releasing.md` | full rewrite: local `prepare` → `qualify` → `publish`, resumability, GHCR one-time auth, from-scratch verification. No mention of a tag-triggered build. |
| `docs/architecture.md` | "Distribution" section: replace the `tag → release.yml → …` diagram with `local qualify → local publish → GHCR/Release`; state the three-role split (Actions = lightweight CI; workstation = heavy build + qualification + OCI publication; GitHub/GHCR = distribution). |
| `README.md` | "Consuming the toolchain" wording near line 50; "See `docs/releasing.md`…" pointer near line 108. |
| `Makefile` | `help` text for `prepare` / `qualify` / `publish`; drop the `release` line (or point it at the new flow). |
| `scripts/*.sh` header comments | no references to `release.yml` building/publishing the image. |

Historical qualification evidence in the course repositories and in
`systems-verification/docs/qualification/**` is not modified.

## 11. Validation performed during implementation

New `scripts/test_release.sh` (same style as the existing `test_*.sh`), using a
tiny stub image tagged `hdl-course-toolchain:latest` and PATH shims for `docker`
and `gh`, asserting:

- stale qualification record (source_commit mismatch) → `publish` aborts;
- changed build inputs after qualification → aborts;
- changed release inputs after qualification → aborts;
- wrong local image (ID mismatch) → aborts;
- version mismatch (arg vs record, and file vs record) → aborts;
- incomplete record (`status != "passed"`, missing file) → aborts;
- git tag already exists pointing elsewhere → aborts;
- GHCR versioned image already exists with a different digest → aborts;
- safe resume when `.out/publish.json` + live state show matching resources;
- `SHA256SUMS` content is correct for the four assets;
- `prepare` guards: not on `main`, dirty tree, version already used → abort;
- `prepare` idempotency when HEAD already pins the target;
- existing launcher / installer / uninstaller suites still pass
  (`make test`);
- grep guard: no file under `.github/workflows/` triggers `on: push: tags` or
  runs `make build` / `make fetch` / a GHCR step.

The **real** `make qualify` (~1h from-source build) is deliberately **not** run
during implementation. It is run once, for real, as part of the actual release
sequence, so the record belongs to exactly the commit that gets published:

```bash
make prepare VERSION=v1.3.1
make qualify
make publish VERSION=v1.3.1
```

The real `make publish` cannot be exercised here — it needs the maintainer's
`write:packages` credential and performs real, immutable registry writes.

## 12. Out of scope / untouched

- `bin/hdl-toolchain`, `install.sh`, `uninstall.sh` behaviour and architecture
  (only their pinned `VERSION` / `SHA256` lines are rewritten by `prepare`, as
  today).
- `scripts/configure.py`, `scripts/versions.py`, `versions.yml`, the
  `Containerfile`, `make bump` / `make updates`.
- `systems-testing-and-certification`, `systems-verification`, and every other
  consumer repository.
- Historical tags `v1.0.0` / `v1.1.0` / `v1.2.0` and their releases.
