# Releasing the toolchain

This repository publishes three things for a release `vX.Y.Z`:

| Artifact | Where | Mutable? |
|---|---|---|
| `ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z` | GHCR | **never** rewritten |
| `ghcr.io/esd-univr/hdl-course-toolchain:latest` | GHCR | moves only on a new qualified release |
| GitHub Release `vX.Y.Z` with `hdl-toolchain`, `install.sh`, `uninstall.sh`, `SHA256SUMS` | Releases page | assets are the tagged source; never re-cut |

Students consume `:latest` through the installed `hdl-toolchain` launcher and
never clone this repository. Courses pin `…:vX.Y.Z@sha256:…` for reproducible
qualification.

`toolchain-release qualification` (this document) is **not** the same as
`course/lesson qualification`, which each course repository owns.

---

## 0. Prerequisites

- `docker` with `buildx`, `gh` authenticated against `esd-univr`, push rights to
  the GHCR package and the ability to push tags to `origin`.
- A clean `main` checkout.

## 1. Qualify the candidate

Qualification is a deliberate, human-run step. It is **not** automated, so that
nobody can publish an image that was never exercised.

```bash
git switch main && git pull
make qualify
```

`make qualify` runs, in order: repository checks → OCI image build → Docker
`toolchain-doctor` → Apptainer SIF build → Apptainer `toolchain-doctor`. It ends
with an evidence block: image id, build-inputs digest, source commit,
architecture. **Keep that block** — it is what you paste into the release notes.

If any tool pins moved since the last release, that is expected: `make updates`
shows what is current, `make bump TOOL=… VERSION=…` moves one pin, and the pin
move is itself a qualification decision recorded in `versions.yml`.

## 2. Choose the next version

```bash
git tag -l                     # what exists
cat VERSION                    # what the tree currently claims
gh release list --repo esd-univr/hdl-course-toolchain
```

Semantic intent:

- **patch** `vX.Y.Z+1` — packaging or launcher fix, identical tool set.
- **minor** `vX.Y+1.0` — tool version bumps, new tools, additive launcher/installer capability.
- **major** `vX+1.0.0` — a change consumers must react to (image namespace, launcher contract, dropped engine).

Never reuse an existing tag for different content. `v1.0.0`, `v1.1.0`, `v1.2.0`
are spent. `v1.3.0` is the first release with the GHCR image + installer model.

## 3. Cut the release (git half)

```bash
make release VERSION=vX.Y.Z
```

`scripts/release.sh` refuses to continue if:

- the tree is dirty or you are not on `main`;
- the tag exists locally or on `origin`;
- a GitHub release `vX.Y.Z` already exists;
- `ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z` already exists in GHCR;
- `make check`, the launcher tests, or the installer tests fail.

It then pins the version into `VERSION`, `bin/hdl-toolchain`
(`LAUNCHER_VERSION`), `install.sh` (`VERSION` + the launcher's SHA-256) and
`uninstall.sh` (`VERSION`), re-runs the tests, commits `release: vX.Y.Z`,
creates the **annotated** tag, and — after a confirmation prompt — pushes `main`
and the tag.

## 4. CI publishes everything else

Pushing the tag triggers `.github/workflows/release.yml`:

| Job | Does |
|---|---|
| `guard` | re-checks tag ↔ `VERSION` ↔ `install.sh` ↔ launcher agreement; refuses if the image tag or the release already exist; runs `make check` + shellcheck + tests |
| `image` | `make fetch` → `make build` tagging `ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z` → `toolchain-doctor` inside it → push `:vX.Y.Z`, then `docker tag … :latest` and push `:latest` |
| `release` | build `SHA256SUMS` over `hdl-toolchain` + `install.sh` + `uninstall.sh`, `gh release create vX.Y.Z --verify-tag` with the four assets and generated notes carrying the image digest |

Watch it:

```bash
gh run watch "$(gh run list --workflow=release.yml -L1 --json databaseId --jq '.[0].databaseId')"
```

> The `image` job compiles Verilator, Yosys, OpenROAD, HARM and HIF from
> source. On a hosted runner this is long and may approach the job time limit.
> If it does, add a self-hosted `linux/amd64` runner and change the `image`
> job's `runs-on:` to its label — nothing else in the workflow changes.

If CI fails **after** the tag was pushed, fix forward: the tag and the
`release: vX.Y.Z` commit stay, you push the fix to `main`, and re-run the failed
jobs (`gh run rerun <id> --failed`). Never delete and re-push a published tag.

## 5. Verify the public path from scratch

```bash
# a throwaway HOME, nothing from this checkout on PATH
tmp="$(mktemp -d)"
env -i HOME="$tmp" PATH=/usr/bin:/bin SHELL=/bin/bash \
    sh -c 'curl -fsSL https://github.com/esd-univr/hdl-course-toolchain/releases/latest/download/install.sh | sh'
"$tmp/.local/bin/hdl-toolchain" --version
"$tmp/.local/bin/hdl-toolchain" --workspace "$tmp" -- toolchain-doctor
```

The launcher should pull `ghcr.io/esd-univr/hdl-course-toolchain:latest`, print
the digest CI published, and the doctor should pass.

Cross-check the digest:

```bash
gh release view vX.Y.Z --json body --jq .body | grep sha256
docker buildx imagetools inspect ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z
```

## 6. Adopt it in the courses (separate, per course)

A course moves to the new toolchain only after **that course's** own
qualification passes against `…:vX.Y.Z@sha256:…`. That work lives in the course
repository (`toolchain-baseline.yml`, `make qualify`), not here. Publishing the
image does not qualify any course.
