# Local Release Machinery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move OCI image build + qualification + GHCR/Release publication off GitHub Actions and onto the maintainer workstation, as an explicit `make prepare` → `make qualify` → `make publish` flow where publication proves — never rebuilds — that the published image is the exact locally qualified one.

**Architecture:** `make qualify` builds the image and, only from a clean tree with all five stages green, writes `.out/qualification.json` binding the qualified Docker image ID to `HEAD`, the `VERSION`, and two content fingerprints. `make prepare` pins the version and commits `release: vX.Y.Z` (nothing else). `make publish` validates the record against the current tree/image, then pushes `:vX.Y.Z`, moves `:latest`, tags, and cuts the GitHub Release — every step resumable via `.out/publish.json`. `.github/workflows/release.yml` is deleted; GitHub Actions keeps only `check.yml`.

**Tech Stack:** GNU Make, Bash (POSIX-ish, `set -euo pipefail`), Python 3.10+ stdlib only (`json`, `argparse`, `unittest`), `docker` (with `buildx`), `gh` CLI, `git`.

**Spec:** `docs/superpowers/specs/2026-09-09-local-release-machinery-design.md` — read it alongside this plan.

## Global Constraints

- Publication **never** runs `docker build` / `make build` / `make fetch`. `make publish` must fail closed if no valid qualification record exists.
- The binding identity between qualification and publication is the Docker image ID `docker_image_id` (`docker image inspect --format '{{.Id}}'`), a `sha256:…` string. A matching `hdl-course-toolchain:latest` tag or a matching `org.opencontainers.image.revision` label is **never** sufficient on its own.
- `make qualify` deletes any stale `.out/qualification.json` at start, then requires `git status --porcelain` to be empty **before building**, and only writes the record if all five stages passed and the tree is still clean.
- `make prepare` requires: branch `main`; clean tree; `git rev-parse HEAD == git rev-parse origin/main` exactly after `git fetch origin` (the idempotent-resume path is the only exception); version unused across local tag, origin tag, GitHub Release, and GHCR `:vX.Y.Z`.
- Versioned GHCR tag `ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z` is immutable. `:latest` moves only after `:vX.Y.Z` is confirmed published.
- Release assets: `hdl-toolchain`, `install.sh`, `uninstall.sh`, `SHA256SUMS`. `SHA256SUMS` contains `sha256sum` lines for the first three only — it does not checksum itself.
- Version format: `v[0-9]+\.[0-9]+\.[0-9]+`. `VERSION` file holds the bare `X.Y.Z`; `bin/hdl-toolchain` `LAUNCHER_VERSION="X.Y.Z"`; `install.sh`/`uninstall.sh` `VERSION="vX.Y.Z"`; between releases the installer/uninstaller sentinel is `VERSION="v0.0.0-dev"`.
- GHCR image reference base: `ghcr.io/esd-univr/hdl-course-toolchain`. Repo: `esd-univr/hdl-course-toolchain`. Qualified platform: `linux/amd64` (arch label `x86_64`).
- No new third-party dependencies. Python: stdlib only. Shell scripts must pass `shellcheck -S warning`.
- Commit messages: no `Co-Authored-By`, no `Claude-Session`, no "Generated with" footer (repo-wide rule). Conventional prefixes (`feat:`, `test:`, `docs:`, `chore:`, `refactor:`).
- Course repositories (`systems-testing-and-certification`, `systems-verification`) are never modified.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `scripts/qualification.py` | Read/write/verify `.out/qualification.json`. Pure — no subprocess, no network. Subcommands `record`, `verify`, `get`. |
| `scripts/test_qualification.py` | `unittest` coverage for `qualification.py` (auto-discovered by `make check`). |
| `scripts/release_lib.sh` | Sourced Bash helpers shared by `prepare-release.sh` and `publish-release.sh`: fingerprints, git/gh/registry probes, guards. |
| `scripts/prepare-release.sh` | Phase 1 — preconditions, pin the version into the four files, run fast tests, commit `release: vX.Y.Z`. |
| `scripts/publish-release.sh` | Phase 3 — validate the record, push `:vX.Y.Z`, move `:latest`, tag, cut the Release. Resumable. Never builds. |
| `scripts/test_release.sh` | Bash integration tests for `prepare-release.sh` and `publish-release.sh` using PATH-shimmed `docker`/`gh` and a bare-repo origin. Added to `make test`. |

**Modified:**

| File | Change |
|---|---|
| `Makefile` | `qualify`: clean-tree gate + stale-record delete + record write. New `prepare`, `publish` targets. `release`: replaced by an error stub. Help text. |
| `.github/workflows/release.yml` | **Deleted.** |
| `.github/workflows/check.yml` | Comment/name touch-ups only if needed; the globbed shellcheck and `make test` already pick up new files. |
| `scripts/release.sh` | **Deleted** (replaced by `prepare-release.sh` + `publish-release.sh`). |
| `docs/releasing.md` | Full rewrite around local `prepare`/`qualify`/`publish`. |
| `docs/architecture.md` | "Distribution" section rewritten; three-role split stated. |
| `README.md` | "Consuming the toolchain" wording (~line 50); releasing pointer (~line 108). |

**Deleted at runtime by `make clean` / `make qualify`:** `.out/qualification.json`, `.out/publish.json` (both under the already-gitignored `.out/`).

---

## Task 1: Clean up the failed `v1.3.1` attempt and rebase the feature branch

**Executed directly by the lead session, not a subagent.** The `origin/main` force-update needs the maintainer's explicit go-ahead at that step.

**Files:** none in-repo; git history + origin refs only.

**Interfaces:**
- Produces: a reconstructed `main` at `cbfbdd0` + `e6c122a' f977e9c' e26b192'`; `feature/local-release-machinery` rebased onto it carrying only spec/plan commits; no `v1.3.1` tag anywhere.

- [ ] **Step 1: Safety branch + confirm inventory**

```bash
cd hdl-course-toolchain
git branch backup/pre-cleanup-main main
git fetch origin
# Re-confirm (must match the spec §3.1 table):
git tag | grep -x v1.3.1            # exists locally
git tag | grep -x v1.3.0 || echo "v1.3.0 local: absent"
gh api repos/esd-univr/hdl-course-toolchain/git/ref/tags/v1.3.1 --jq .ref   # exists
gh api repos/esd-univr/hdl-course-toolchain/git/ref/tags/v1.3.0 2>&1 | grep -q 'Not Found' && echo "v1.3.0 origin: absent"
gh release view v1.3.1 2>&1 | grep -qi 'not found' && echo "v1.3.1 release: absent"
gh release view v1.3.0 2>&1 | grep -qi 'not found' && echo "v1.3.0 release: absent"
```

Expected: `v1.3.1` tag exists local + origin; everything else absent. If any GHCR image or GitHub Release for either version turns out to exist, **stop** and report — do not proceed.

- [ ] **Step 2: Delete the `v1.3.1` tag (local + origin)**

```bash
git tag -d v1.3.1
gh api -X DELETE repos/esd-univr/hdl-course-toolchain/git/refs/tags/v1.3.1
gh api repos/esd-univr/hdl-course-toolchain/git/ref/tags/v1.3.1 2>&1 | grep -q 'Not Found' && echo "origin tag deleted"
```

- [ ] **Step 3: Reconstruct `main` locally**

```bash
git switch main
git reset --hard cbfbdd0
git cherry-pick e6c122a f977e9c e26b192
```

Expected: three clean cherry-picks, no conflicts.

- [ ] **Step 4: Verify the honest unreleased tree BEFORE touching origin**

```bash
test "$(cat VERSION)" = "1.3.0"
grep -qx 'LAUNCHER_VERSION="1.3.0"' bin/hdl-toolchain
grep -qx 'VERSION="v0.0.0-dev"' install.sh
grep -qx 'VERSION="v0.0.0-dev"' uninstall.sh
./scripts/sync-installer-digest.sh --check
make check
```

Expected: every command exits 0. If not, `git reset --hard backup/pre-cleanup-main` and report.

- [ ] **Step 5: Force-update `origin/main` (needs maintainer go-ahead)**

Ask the maintainer to confirm, then:

```bash
NEW=$(git rev-parse HEAD)
gh api -X PATCH repos/esd-univr/hdl-course-toolchain/git/refs/heads/main -f sha="$NEW" -F force=true --jq .object.sha
# or, with ssh available: git push --force origin main
git fetch origin && git rev-parse origin/main   # must equal $NEW
```

- [ ] **Step 6: Rebase the feature branch onto the new main**

```bash
git switch feature/local-release-machinery
git rebase --onto main 6805fa1 feature/local-release-machinery
# feature branch now = new main + spec + spec-amend + plan commits (already committed)
git merge-base --is-ancestor 30cb593 HEAD && echo "BAD: v1.3.0 still ancestor" || echo "OK: 30cb593 gone"
git merge-base --is-ancestor 6805fa1 HEAD && echo "BAD: v1.3.1 still ancestor" || echo "OK: 6805fa1 gone"
git log --oneline main..HEAD    # only spec + plan commits, no "release:" commits
```

Expected: both `is-ancestor` checks print `OK`. The spec and plan commits are
already on the branch before Task 1 runs; the rebase just re-parents them onto
the reconstructed `main`.

---

## Task 2: `scripts/qualification.py` — record model + `record` subcommand

**Files:**
- Create: `scripts/qualification.py`
- Test: `scripts/test_qualification.py`

**Interfaces:**
- Produces:
  - CLI `python3 scripts/qualification.py record --out <path> --version vX.Y.Z --source-commit <sha> --tree-clean {0,1} --build-inputs-sha256 <h> --release-inputs-sha256 <h> --docker-image-ref <ref> --docker-image-id sha256:<h> --sif-path <p> --sif-sha256 <h> --platform linux/amd64 --arch x86_64 --doctor-docker pass --doctor-apptainer pass` → writes the JSON file with `schema=1`, `status="passed"`, `qualified_at` = current UTC ISO-8601 (`Z` suffix), exit 0. Refuses (exit 2) if `--tree-clean` is not `1`.
  - Module constant `SCHEMA = 1`.
  - `load(path) -> dict` raising `QualificationError` (subclass of `Exception`) on missing file / bad JSON / wrong schema / `status != "passed"`.

- [ ] **Step 1: Write the failing test**

```python
# scripts/test_qualification.py
import json, subprocess, sys, tempfile, unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
QUAL = HERE / "qualification.py"

def run(*args):
    return subprocess.run([sys.executable, str(QUAL), *args],
                          capture_output=True, text=True)

FULL = dict(
    version="v1.3.1", source_commit="a" * 40, tree_clean="1",
    build_inputs_sha256="b" * 64, release_inputs_sha256="c" * 64,
    docker_image_ref="hdl-course-toolchain:latest",
    docker_image_id="sha256:" + "d" * 64,
    sif_path=".out/hdl-course-toolchain.sif", sif_sha256="e" * 64,
    platform="linux/amd64", arch="x86_64",
    doctor_docker="pass", doctor_apptainer="pass",
)

def record_args(out, **over):
    d = {**FULL, **over}
    return ["record", "--out", str(out),
            "--version", d["version"], "--source-commit", d["source_commit"],
            "--tree-clean", d["tree_clean"],
            "--build-inputs-sha256", d["build_inputs_sha256"],
            "--release-inputs-sha256", d["release_inputs_sha256"],
            "--docker-image-ref", d["docker_image_ref"],
            "--docker-image-id", d["docker_image_id"],
            "--sif-path", d["sif_path"], "--sif-sha256", d["sif_sha256"],
            "--platform", d["platform"], "--arch", d["arch"],
            "--doctor-docker", d["doctor_docker"],
            "--doctor-apptainer", d["doctor_apptainer"]]

class RecordTests(unittest.TestCase):
    def test_record_writes_passed_record(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "qualification.json"
            r = run(*record_args(out))
            self.assertEqual(r.returncode, 0, r.stderr)
            rec = json.loads(out.read_text())
            self.assertEqual(rec["schema"], 1)
            self.assertEqual(rec["status"], "passed")
            self.assertEqual(rec["version"], "v1.3.1")
            self.assertEqual(rec["source_tree_clean"], True)
            self.assertTrue(rec["qualified_at"].endswith("Z"))

    def test_record_refuses_dirty_tree(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "qualification.json"
            r = run(*record_args(out, tree_clean="0"))
            self.assertEqual(r.returncode, 2)
            self.assertFalse(out.exists())

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it, verify it fails**

Run: `python3 -m unittest scripts.test_qualification -v` (from repo root)
Expected: FAIL — `qualification.py` does not exist.

- [ ] **Step 3: Implement `record` + model**

```python
#!/usr/bin/env python3
"""Read, write and verify the local qualification record (.out/qualification.json).

Pure: no subprocess, no network. `make qualify` calls `record`; `make publish`
calls `verify`; release-note assembly calls `get`.
"""
import argparse
import datetime as _dt
import json
import sys

SCHEMA = 1


class QualificationError(Exception):
    pass


def _utc_now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            rec = json.load(fh)
    except FileNotFoundError as exc:
        raise QualificationError(
            "no qualification record — run 'make qualify'") from exc
    except (OSError, ValueError) as exc:
        raise QualificationError(f"qualification record unreadable: {exc}") from exc
    if rec.get("schema") != SCHEMA:
        raise QualificationError(
            f"qualification record schema {rec.get('schema')!r}, expected {SCHEMA}")
    if rec.get("status") != "passed":
        raise QualificationError(
            "qualification record does not say 'passed' — run 'make qualify'")
    return rec


def cmd_record(a: argparse.Namespace) -> int:
    if a.tree_clean != "1":
        print("qualification: refusing to record a dirty tree", file=sys.stderr)
        return 2
    rec = {
        "schema": SCHEMA,
        "status": "passed",
        "version": a.version,
        "source_commit": a.source_commit,
        "source_tree_clean": True,
        "build_inputs_sha256": a.build_inputs_sha256,
        "release_inputs_sha256": a.release_inputs_sha256,
        "docker_image_ref": a.docker_image_ref,
        "docker_image_id": a.docker_image_id,
        "sif_path": a.sif_path,
        "sif_sha256": a.sif_sha256,
        "platform": a.platform,
        "architecture": a.arch,
        "doctor_docker": a.doctor_docker,
        "doctor_apptainer": a.doctor_apptainer,
        "qualified_at": _utc_now_iso(),
    }
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"qualification: recorded {a.version} @ {a.source_commit[:12]} "
          f"({a.docker_image_id[:19]})")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="qualification.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("record", help="write a passed qualification record")
    r.add_argument("--out", required=True)
    r.add_argument("--version", required=True)
    r.add_argument("--source-commit", required=True)
    r.add_argument("--tree-clean", required=True, choices=["0", "1"])
    r.add_argument("--build-inputs-sha256", required=True)
    r.add_argument("--release-inputs-sha256", required=True)
    r.add_argument("--docker-image-ref", required=True)
    r.add_argument("--docker-image-id", required=True)
    r.add_argument("--sif-path", required=True)
    r.add_argument("--sif-sha256", required=True)
    r.add_argument("--platform", required=True)
    r.add_argument("--arch", required=True)
    r.add_argument("--doctor-docker", required=True)
    r.add_argument("--doctor-apptainer", required=True)
    r.set_defaults(func=cmd_record)
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python3 -m unittest scripts.test_qualification -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/qualification.py scripts/test_qualification.py
git commit -m "feat: qualification record model and 'record' subcommand"
```

---

## Task 3: `qualification.py verify` and `get` subcommands

**Files:**
- Modify: `scripts/qualification.py`
- Modify: `scripts/test_qualification.py`

**Interfaces:**
- Consumes: `load()`, `QualificationError` from Task 2.
- Produces:
  - CLI `verify --record <path> --version vX.Y.Z --version-file X.Y.Z --head <sha> --tree-clean {0,1} --build-inputs-sha256 <h> --release-inputs-sha256 <h> --image-id sha256:<h>` → exit 0 if every field matches the record, else exit 1 having printed one `qualification: <field> mismatch (record <a>, now <b>)` line per mismatch. Missing/!passed record → exit 1 with the `QualificationError` message.
  - CLI `get --record <path> --field <name>` → prints the record value for `<name>` (used by release notes: `version`, `source_commit`, `architecture`, `build_inputs_sha256`, `qualified_at`, `doctor_docker`, `doctor_apptainer`), exit 0; unknown field → exit 2.

- [ ] **Step 1: Write the failing tests**

```python
# append to scripts/test_qualification.py
class VerifyTests(unittest.TestCase):
    def _record(self, t, **over):
        out = Path(t) / "qualification.json"
        self.assertEqual(run(*record_args(out, **over)).returncode, 0)
        return out

    def _verify_args(self, rec, **over):
        d = dict(version="v1.3.1", version_file="1.3.1", head="a" * 40,
                 tree_clean="1", build_inputs_sha256="b" * 64,
                 release_inputs_sha256="c" * 64, image_id="sha256:" + "d" * 64)
        d.update(over)
        return ["verify", "--record", str(rec),
                "--version", d["version"], "--version-file", d["version_file"],
                "--head", d["head"], "--tree-clean", d["tree_clean"],
                "--build-inputs-sha256", d["build_inputs_sha256"],
                "--release-inputs-sha256", d["release_inputs_sha256"],
                "--image-id", d["image_id"]]

    def test_verify_ok(self):
        with tempfile.TemporaryDirectory() as t:
            rec = self._record(t)
            self.assertEqual(run(*self._verify_args(rec)).returncode, 0)

    def test_verify_head_moved(self):
        with tempfile.TemporaryDirectory() as t:
            rec = self._record(t)
            r = run(*self._verify_args(rec, head="f" * 40))
            self.assertEqual(r.returncode, 1)
            self.assertIn("source_commit mismatch", r.stdout + r.stderr)

    def test_verify_image_id_mismatch(self):
        with tempfile.TemporaryDirectory() as t:
            rec = self._record(t)
            r = run(*self._verify_args(rec, image_id="sha256:" + "9" * 64))
            self.assertEqual(r.returncode, 1)
            self.assertIn("docker_image_id mismatch", r.stdout + r.stderr)

    def test_verify_dirty_now(self):
        with tempfile.TemporaryDirectory() as t:
            rec = self._record(t)
            r = run(*self._verify_args(rec, tree_clean="0"))
            self.assertEqual(r.returncode, 1)

    def test_verify_missing_record(self):
        r = run("verify", "--record", "/nonexistent/q.json",
                *self._verify_args(Path("/x"))[3:])
        self.assertEqual(r.returncode, 1)
        self.assertIn("run 'make qualify'", r.stdout + r.stderr)

class GetTests(unittest.TestCase):
    def test_get_field(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "q.json"
            run(*record_args(out))
            r = run("get", "--record", str(out), "--field", "source_commit")
            self.assertEqual(r.returncode, 0)
            self.assertEqual(r.stdout.strip(), "a" * 40)
```

- [ ] **Step 2: Run, verify fail**

Run: `python3 -m unittest scripts.test_qualification -v`
Expected: FAIL — `verify` / `get` subcommands unknown.

- [ ] **Step 3: Implement `verify` + `get`**

```python
# add to qualification.py

_VERIFY_FIELDS = [
    ("version", "version"),
    ("version", "version_file"),          # both CLI inputs compared to record["version"]
    ("source_commit", "head"),
    ("build_inputs_sha256", "build_inputs_sha256"),
    ("release_inputs_sha256", "release_inputs_sha256"),
    ("docker_image_id", "image_id"),
]


def cmd_verify(a: argparse.Namespace) -> int:
    try:
        rec = load(a.record)
    except QualificationError as exc:
        print(f"qualification: {exc}", file=sys.stderr)
        return 1

    now = {
        "version": a.version,
        "version_file": a.version_file,
        "head": a.head,
        "build_inputs_sha256": a.build_inputs_sha256,
        "release_inputs_sha256": a.release_inputs_sha256,
        "image_id": a.image_id,
    }
    bad = 0
    for rec_key, cli_key in _VERIFY_FIELDS:
        want, got = rec[rec_key], now[cli_key]
        if want != got:
            bad += 1
            label = "source_commit" if cli_key == "head" else (
                "docker_image_id" if cli_key == "image_id" else rec_key)
            print(f"qualification: {label} mismatch "
                  f"(record {want}, now {got})")
    if a.tree_clean != "1":
        bad += 1
        print("qualification: working tree is dirty now (was clean at qualify)")
    if not rec.get("source_tree_clean"):
        bad += 1
        print("qualification: record was not made from a clean tree")
    if bad:
        print(f"qualification: {bad} mismatch(es) — re-run 'make qualify' on HEAD",
              file=sys.stderr)
        return 1
    print("qualification: record matches the current tree, VERSION and image")
    return 0


def cmd_get(a: argparse.Namespace) -> int:
    rec = load(a.record)
    if a.field not in rec:
        print(f"qualification: no field {a.field!r}", file=sys.stderr)
        return 2
    print(rec[a.field])
    return 0
```

Wire both into `build_parser()`:

```python
    v = sub.add_parser("verify", help="check a record against the current state")
    for opt in ("--record", "--version", "--version-file", "--head",
                "--build-inputs-sha256", "--release-inputs-sha256", "--image-id"):
        v.add_argument(opt, required=True)
    v.add_argument("--tree-clean", required=True, choices=["0", "1"])
    v.set_defaults(func=cmd_verify)

    g = sub.add_parser("get", help="print one field of a record")
    g.add_argument("--record", required=True)
    g.add_argument("--field", required=True)
    g.set_defaults(func=cmd_get)
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python3 -m unittest scripts.test_qualification -v`
Expected: PASS (all Record/Verify/Get tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/qualification.py scripts/test_qualification.py
git commit -m "feat: qualification 'verify' and 'get' subcommands"
```

---

## Task 4: `scripts/release_lib.sh` — fingerprints and probes

**Files:**
- Create: `scripts/release_lib.sh`
- Modify: `scripts/test_release.sh` (created here with its first cases)

**Interfaces:**
- Consumes: `scripts/artifact-status.sh` (existing) for the docker build-inputs fingerprint.
- Produces (functions, all `set -euo pipefail`-safe, sourced via `. "$(dirname "$0")/release_lib.sh"`):
  - `release_inputs_fingerprint` → prints `sha256` over `VERSION`, `bin/hdl-toolchain`, `install.sh`, `uninstall.sh` (same construction as `artifact-status.sh`: `sha256sum` each existing file, pipe the list through `sha256sum`, take field 1).
  - `build_inputs_fingerprint` → prints the docker fingerprint by calling `scripts/artifact-status.sh` internals; implement by having `artifact-status.sh` grow a `fingerprint docker` subcommand (see Step 3) and calling it.
  - `ghcr_ref <version>` → prints `ghcr.io/esd-univr/hdl-course-toolchain:<version>`.
  - `origin_tag_object_sha <version>` → prints the commit sha the origin tag `<version>` resolves to, or empty + return 1 if absent (`gh api repos/esd-univr/hdl-course-toolchain/git/ref/tags/<version>`; when the ref is an annotated tag object, dereference via `gh api .../git/tags/<sha> --jq .object.sha`).
  - `gh_release_exists <version>` → return 0 if `gh release view <version>` succeeds.
  - `ghcr_manifest_digest <version>` → prints the registry digest of `:<version>` (`docker buildx imagetools inspect --format '{{json .Manifest.Digest}}'` stripped of quotes), or empty + return 1 if the tag is absent.
  - `remote_image_id <version> <platform>` → `docker pull --platform <platform> <ref> >/dev/null` then `docker image inspect --format '{{.Id}}' <ref>`; empty + return 1 on pull failure.
  - `die <msg>` → prints `release: <msg>` to stderr, exit 1.
  - `REPO="esd-univr/hdl-course-toolchain"`, `IMAGE_BASE="ghcr.io/esd-univr/hdl-course-toolchain"`, `PLATFORM_DEFAULT="linux/amd64"` constants.

- [ ] **Step 1: Add a `fingerprint` subcommand to `artifact-status.sh`**

In `scripts/artifact-status.sh`, after the `MODE`/`ENGINE` parsing, add:

```bash
if [ "${1:-}" = "fingerprint" ]; then
    # `artifact-status.sh fingerprint docker|apptainer` — print the build-input
    # fingerprint without comparing it to any recorded stamp.
    shift
    ENGINE="${1:-docker}"
    fingerprint
    exit 0
fi
```

(The `fingerprint` function and `inputs` helper already exist and are engine-independent for `docker`.)

- [ ] **Step 2: Write failing test for the fingerprints**

```bash
# scripts/test_release.sh  (new file — full harness scaffold)
#!/usr/bin/env bash
# Integration tests for prepare-release.sh / publish-release.sh / release_lib.sh.
# Never touches the real origin or a real registry: docker and gh are PATH stubs
# that log their arguments and answer from files in a scratch dir; origin is a
# local bare repo.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; [ $# -gt 1 ] && printf '    got: %s\n' "$2"; }
has()   { case "$2" in *"$3"*) ok ;; *) bad "$1 — expected to contain: $3" "$2" ;; esac; }
eq()    { [ "$2" = "$3" ] && ok || bad "$1 — expected '$3'" "$2"; }
neq0()  { [ "$2" != "0" ] && ok || bad "$1 — expected non-zero exit" "$2"; }

echo "== release_lib.sh tests =="
(
  cd "$ROOT"
  . scripts/release_lib.sh
  fp1="$(release_inputs_fingerprint)"
  eq "release_inputs_fingerprint is 64 hex" "$(printf '%s' "$fp1" | wc -c | tr -d ' ')" "64"
  # mutating a release input changes the fingerprint
  tmp="$(mktemp)"; cp VERSION "$tmp"
  printf 'x\n' >> VERSION
  fp2="$(release_inputs_fingerprint)"
  [ "$fp1" != "$fp2" ] && ok || bad "fingerprint should change when VERSION changes"
  cp "$tmp" VERSION; rm -f "$tmp"
  eq "ghcr_ref" "$(ghcr_ref v1.3.1)" "ghcr.io/esd-univr/hdl-course-toolchain:v1.3.1"
)

echo
echo "release_lib: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 3: Run, verify fail**

Run: `bash scripts/test_release.sh`
Expected: FAIL — `release_lib.sh` not found.

- [ ] **Step 4: Implement `release_lib.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for prepare-release.sh and publish-release.sh. Source, do not
# execute:  . "$(dirname "$0")/release_lib.sh"
# shellcheck shell=bash

REPO="esd-univr/hdl-course-toolchain"
IMAGE_BASE="ghcr.io/esd-univr/hdl-course-toolchain"
PLATFORM_DEFAULT="linux/amd64"

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT="$(dirname "${_LIB_DIR}")"

die() { echo "release: $*" >&2; exit 1; }

ghcr_ref() { printf '%s:%s\n' "${IMAGE_BASE}" "$1"; }

release_inputs_fingerprint() {
    { for f in VERSION bin/hdl-toolchain install.sh uninstall.sh; do
        [ -f "${_ROOT}/${f}" ] && sha256sum "${_ROOT}/${f}"
      done; } | sha256sum | cut -d' ' -f1
}

build_inputs_fingerprint() {
    "${_LIB_DIR}/artifact-status.sh" fingerprint docker
}

gh_release_exists() { gh release view "$1" >/dev/null 2>&1; }

origin_tag_object_sha() {
    local ref sha typ
    ref="$(gh api "repos/${REPO}/git/ref/tags/$1" 2>/dev/null)" || return 1
    typ="$(printf '%s' "${ref}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["object"]["type"])')"
    sha="$(printf '%s' "${ref}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["object"]["sha"])')"
    if [ "${typ}" = "tag" ]; then
        gh api "repos/${REPO}/git/tags/${sha}" --jq '.object.sha' 2>/dev/null || return 1
    else
        printf '%s\n' "${sha}"
    fi
}

ghcr_manifest_digest() {
    docker buildx imagetools inspect "$(ghcr_ref "$1")" \
        --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"' | grep . || return 1
}

remote_image_id() {
    local ref="$(ghcr_ref "$1")" platform="${2:-$PLATFORM_DEFAULT}"
    docker pull --platform "${platform}" "${ref}" >/dev/null 2>&1 || return 1
    docker image inspect --format '{{.Id}}' "${ref}" 2>/dev/null || return 1
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `bash scripts/test_release.sh && shellcheck -S warning scripts/release_lib.sh scripts/test_release.sh scripts/artifact-status.sh`
Expected: PASS + clean shellcheck.

- [ ] **Step 6: Commit**

```bash
git add scripts/release_lib.sh scripts/test_release.sh scripts/artifact-status.sh
git commit -m "feat: release_lib.sh shared helpers + artifact-status fingerprint subcommand"
```

---

## Task 5: `make qualify` — clean-tree gate + record write

**Files:**
- Modify: `Makefile` (the `qualify` target)

**Interfaces:**
- Consumes: `scripts/qualification.py record`, `release_lib.sh` fingerprints, existing `make check/build/doctor/sif/doctor-sif`.
- Produces: `.out/qualification.json` on success; `.out/qualification.json` absent on any failure.

- [ ] **Step 1: Add a guard + record recipe to the `qualify` target**

Replace the `qualify:` recipe in `Makefile` with:

```make
qualify: ## Run the full release qualification in order and record it
	@rm -f .out/qualification.json
	@test -z "$$(git status --porcelain)" || { \
	    printf 'qualify: working tree is dirty; commit or stash before qualifying\n' >&2; exit 1; }
	@printf '==> 1/5 repository checks\n'
	@$(MAKE) --no-print-directory check
	@printf '\n==> 2/5 OCI image\n'
	@$(MAKE) --no-print-directory build
	@printf '\n==> 3/5 Docker toolchain-doctor\n'
	@$(MAKE) --no-print-directory doctor
	@printf '\n==> 4/5 Apptainer SIF\n'
	@$(MAKE) --no-print-directory sif
	@printf '\n==> 5/5 Apptainer toolchain-doctor\n'
	@$(MAKE) --no-print-directory doctor-sif
	@printf '\n==> recording qualification\n'
	@test -z "$$(git status --porcelain)" || { \
	    printf 'qualify: tree went dirty during qualification; not recording\n' >&2; exit 1; }
	@set -eu; . scripts/release_lib.sh; \
	  python3 scripts/qualification.py record \
	    --out .out/qualification.json \
	    --version "v$$(cat VERSION)" \
	    --source-commit "$$(git rev-parse HEAD)" \
	    --tree-clean 1 \
	    --build-inputs-sha256 "$$(build_inputs_fingerprint)" \
	    --release-inputs-sha256 "$$(release_inputs_fingerprint)" \
	    --docker-image-ref "$(IMAGE):$(TAG)" \
	    --docker-image-id "$$(docker image inspect $(IMAGE):$(TAG) --format '{{.Id}}')" \
	    --sif-path "$(SIF)" \
	    --sif-sha256 "$$(sha256sum "$(SIF)" | cut -d' ' -f1)" \
	    --platform "$${HDL_TOOLCHAIN_PLATFORM:-linux/amd64}" \
	    --arch "$$(uname -m)" \
	    --doctor-docker pass --doctor-apptainer pass
	@printf '\n==> qualification summary\n'
	@printf '    repository checks     PASS\n'
	@printf '    OCI/Docker build      PASS\n'
	@printf '    Docker doctor         PASS\n'
	@printf '    Apptainer SIF build   PASS\n'
	@printf '    Apptainer doctor      PASS\n'
	@printf '    architecture          %s\n' "$$(uname -m)"
	@printf '    image                 %s\n' \
	    "$$(docker image inspect $(IMAGE):$(TAG) --format '{{.Id}}' | cut -c8-19)"
	@printf '    source commit         %s\n' "$$(git rev-parse HEAD)"
	@printf '    record                .out/qualification.json\n'
	@printf '\nQualification passed and recorded. Run: make publish VERSION=v%s\n' "$$(cat VERSION)"
```

- [ ] **Step 2: Syntax-check the Makefile**

Run: `make -n qualify`
Expected: prints the recipe lines, no "missing separator" / parse error.

- [ ] **Step 3: Prove the dirty-tree gate without a full build**

Run:
```bash
touch scripts/_dirtytest && git add scripts/_dirtytest
make qualify 2>&1 | head -3; echo "exit=$?"
git rm -f --cached scripts/_dirtytest >/dev/null; rm -f scripts/_dirtytest
```
Expected: output contains `working tree is dirty`, `exit` non-zero, and `.out/qualification.json` was not created.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "feat: make qualify enforces a clean tree and records .out/qualification.json"
```

---

## Task 6: `scripts/prepare-release.sh` — preconditions

**Files:**
- Create: `scripts/prepare-release.sh`
- Modify: `scripts/test_release.sh`

**Interfaces:**
- Consumes: `release_lib.sh`.
- Produces: executable `scripts/prepare-release.sh vX.Y.Z`. This task implements everything up to (not including) mutating files: argument validation, `main` branch check, clean tree, `git fetch origin` + exact `HEAD == origin/main`, the four "version unused" checks, and the dev-sentinel check. On any failure: `die` with a specific message, exit 1, tree untouched.
- Produces (for Task 7): a function `prepare_preconditions <version>` in the same script, and a `prepare_already_done <version>` helper returning 0 when HEAD is a matching `release: vX.Y.Z` commit whose parent is `origin/main`.

- [ ] **Step 1: Write failing tests (preconditions)**

Add a `test_release.sh` block that builds a scratch git repo with a bare origin, a `VERSION`/`install.sh`/`bin/hdl-toolchain` skeleton, PATH stubs for `gh` (answers "tag/release absent") and `docker` (answers "manifest absent"), then:

```bash
echo "== prepare-release.sh preconditions =="
setup_repo() {
  WORK="$(mktemp -d)"; export WORK
  git init -q -b main "$WORK/up.git" --bare
  git clone -q "$WORK/up.git" "$WORK/repo"
  cd "$WORK/repo"
  git config user.email t@t; git config user.name t
  mkdir -p scripts bin
  cp "$ROOT/scripts/release_lib.sh" "$ROOT/scripts/prepare-release.sh" scripts/
  cp "$ROOT/scripts/artifact-status.sh" scripts/ 2>/dev/null || true
  printf '1.2.0\n' > VERSION
  printf 'LAUNCHER_VERSION="1.2.0"\n' > bin/hdl-toolchain
  printf 'VERSION="v0.0.0-dev"\nSHA256="x"\n' > install.sh
  printf 'VERSION="v0.0.0-dev"\n' > uninstall.sh
  git add -A; git commit -qm init; git push -q origin main
  mkdir "$WORK/stub"
  cat > "$WORK/stub/gh" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"release view"*) exit 1 ;;
  *"git/ref/tags/"*) echo '{"message":"Not Found"}'; exit 1 ;;
  *) exit 0 ;;
esac
S
  cat > "$WORK/stub/docker" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"imagetools inspect"*) exit 1 ;;
  *"manifest inspect"*) exit 1 ;;
  *) exit 0 ;;
esac
S
  chmod +x "$WORK/stub"/*
  export PATH="$WORK/stub:$PATH"
}
teardown_repo() { cd "$ROOT"; rm -rf "$WORK"; }

setup_repo
out="$(bash scripts/prepare-release.sh not-a-version 2>&1)"; neq0 "bad version rejected" "$?"
has "bad version message" "$out" "vX.Y.Z"
git switch -qc side
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "not on main rejected" "$?"
has "not-on-main message" "$out" "main"
git switch -qm main >/dev/null 2>&1 || git switch -q main
echo dirt > dirty; git add dirty
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "dirty tree rejected" "$?"
git reset -q --hard >/dev/null
# ahead of origin/main
git commit -q --allow-empty -m ahead
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; neq0 "ahead of origin rejected" "$?"
has "ahead message" "$out" "origin/main"
git reset -q --hard origin/main
teardown_repo
```

- [ ] **Step 2: Run, verify fail**

Run: `bash scripts/test_release.sh`
Expected: FAIL — `prepare-release.sh` missing.

- [ ] **Step 3: Implement the preconditions**

```bash
#!/usr/bin/env bash
# Phase 1 of a release: pin the version and commit "release: vX.Y.Z". Nothing
# else — no tag, no push, no GHCR, no GitHub Release. See docs/releasing.md.
#
#   scripts/prepare-release.sh vX.Y.Z
set -euo pipefail

_DIR="$(cd "$(dirname "$0")" && pwd)"
_ROOT="$(dirname "${_DIR}")"
# shellcheck source=scripts/release_lib.sh
. "${_DIR}/release_lib.sh"
cd "${_ROOT}"

VERSION="${1:-}"
case "${VERSION}" in
    v[0-9]*.[0-9]*.[0-9]*) : ;;
    *) die "usage: scripts/prepare-release.sh vX.Y.Z" ;;
esac
BARE="${VERSION#v}"

prepare_already_done() {
    # HEAD is a matching release commit whose parent is origin/main, tree clean.
    [ -z "$(git status --porcelain)" ] || return 1
    [ "$(git log -1 --format=%s)" = "release: ${VERSION}" ] || return 1
    [ "$(git rev-parse HEAD^)" = "$(git rev-parse origin/main)" ] || return 1
    grep -qx "VERSION=\"${VERSION}\"" install.sh || return 1
    grep -qx "VERSION=\"${VERSION}\"" uninstall.sh || return 1
    grep -qx "LAUNCHER_VERSION=\"${BARE}\"" bin/hdl-toolchain || return 1
    [ "$(cat VERSION)" = "${BARE}" ] || return 1
}

version_unused() {
    git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null 2>&1 \
        && die "tag ${VERSION} already exists locally"
    origin_tag_object_sha "${VERSION}" >/dev/null 2>&1 \
        && die "tag ${VERSION} already exists on origin"
    gh_release_exists "${VERSION}" \
        && die "a GitHub Release ${VERSION} already exists"
    if ghcr_manifest_digest "${VERSION}" >/dev/null 2>&1; then
        die "$(ghcr_ref "${VERSION}") already exists in GHCR — pick the next version"
    fi
}

prepare_preconditions() {
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "${branch}" = "main" ] || die "not on main (on ${branch})"
    [ -z "$(git status --porcelain)" ] || die "working tree is dirty"
    git fetch --quiet origin
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
        || die "HEAD is not exactly origin/main — pull/push/align main first"
    grep -qx 'VERSION="v0.0.0-dev"' install.sh \
        || die "install.sh is not at the v0.0.0-dev sentinel — a release is already half-pinned"
    version_unused
}

main() {
    if prepare_already_done; then
        echo "prepare: already prepared at HEAD $(git rev-parse --short HEAD) (${VERSION})"
        exit 0
    fi
    prepare_preconditions
    echo "prepare: preconditions OK for ${VERSION}"
    # Task 7 adds the pinning + commit below this line.
}

main "$@"
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bash scripts/test_release.sh && shellcheck -S warning scripts/prepare-release.sh`
Expected: PASS + clean shellcheck.

- [ ] **Step 5: Commit**

```bash
git add scripts/prepare-release.sh scripts/test_release.sh
git commit -m "feat: prepare-release.sh preconditions and idempotent-resume guard"
```

---

## Task 7: `scripts/prepare-release.sh` — pin, test, commit

**Files:**
- Modify: `scripts/prepare-release.sh`
- Modify: `scripts/test_release.sh`

**Interfaces:**
- Consumes: `prepare_preconditions`, `prepare_already_done` from Task 6; `scripts/sync-installer-digest.sh` (existing).
- Produces: after a successful run, a `release: vX.Y.Z` commit on `main` staging exactly `VERSION bin/hdl-toolchain install.sh uninstall.sh`; nothing pushed/tagged.

- [ ] **Step 1: Write failing test (happy path)**

```bash
echo "== prepare-release.sh pins and commits =="
setup_repo
# stub sync-installer-digest.sh and the test suites the script runs
cat > scripts/sync-installer-digest.sh <<'S'
#!/usr/bin/env bash
[ "${1:-}" = "--check" ] && exit 0
sed -i 's/^SHA256=.*/SHA256="deadbeef"/' install.sh
S
chmod +x scripts/sync-installer-digest.sh
mkdir -p scripts
: > Makefile   # `make check` / `make test` become no-ops
printf 'check:\n\t@true\ntest:\n\t@true\n' > Makefile
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; eq "prepare exits 0" "$?" "0"
eq "VERSION pinned" "$(cat VERSION)" "1.3.1"
has "launcher pinned" "$(cat bin/hdl-toolchain)" 'LAUNCHER_VERSION="1.3.1"'
has "installer pinned" "$(cat install.sh)" 'VERSION="v1.3.1"'
eq "commit subject" "$(git log -1 --format=%s)" "release: v1.3.1"
eq "nothing pushed" "$(git rev-parse origin/main)" "$(git rev-parse HEAD^)"
eq "no tag" "$(git tag | wc -l | tr -d ' ')" "0"
# idempotent re-run
out="$(bash scripts/prepare-release.sh v1.3.1 2>&1)"; eq "re-run exits 0" "$?" "0"
has "re-run says already prepared" "$out" "already prepared"
teardown_repo
```

- [ ] **Step 2: Run, verify fail**

Run: `bash scripts/test_release.sh`
Expected: FAIL — script stops after "preconditions OK", does not pin.

- [ ] **Step 3: Implement pin + commit (replace the `main()` tail)**

```bash
pin_version() {
    printf '%s\n' "${BARE}" > VERSION
    sed -i.bak "s/^LAUNCHER_VERSION=\".*\"\$/LAUNCHER_VERSION=\"${BARE}\"/" bin/hdl-toolchain
    sed -i.bak "s/^VERSION=\".*\"\$/VERSION=\"${VERSION}\"/" install.sh
    sed -i.bak "s/^VERSION=\".*\"\$/VERSION=\"${VERSION}\"/" uninstall.sh
    rm -f bin/hdl-toolchain.bak install.sh.bak uninstall.sh.bak
    ./scripts/sync-installer-digest.sh
    grep -qx "LAUNCHER_VERSION=\"${BARE}\"" bin/hdl-toolchain || die "failed to pin the launcher"
    grep -qx "VERSION=\"${VERSION}\"" install.sh || die "failed to pin install.sh"
    grep -qx "VERSION=\"${VERSION}\"" uninstall.sh || die "failed to pin uninstall.sh"
}

main() {
    if prepare_already_done; then
        echo "prepare: already prepared at HEAD $(git rev-parse --short HEAD) (${VERSION})"
        exit 0
    fi
    prepare_preconditions
    pin_version
    echo "prepare: running fast tests against the pinned tree"
    make --no-print-directory check
    make --no-print-directory test
    git add VERSION bin/hdl-toolchain install.sh uninstall.sh
    git commit -m "release: ${VERSION}"
    cat <<EOF

prepare: committed "release: ${VERSION}" at $(git rev-parse --short HEAD)

Next:
  make qualify
  make publish VERSION=${VERSION}

Not yet done (publish does these): git tag, push, GHCR, GitHub Release.
EOF
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bash scripts/test_release.sh && shellcheck -S warning scripts/prepare-release.sh`
Expected: PASS + clean shellcheck.

- [ ] **Step 5: Commit**

```bash
git add scripts/prepare-release.sh scripts/test_release.sh
git commit -m "feat: prepare-release.sh pins the version, runs tests, commits"
```

---

## Task 8: `scripts/publish-release.sh` — validation gate + auth check

**Files:**
- Create: `scripts/publish-release.sh`
- Modify: `scripts/test_release.sh`

**Interfaces:**
- Consumes: `release_lib.sh`; `scripts/qualification.py verify`.
- Produces: executable `scripts/publish-release.sh vX.Y.Z`. This task implements: arg validation; load+verify `.out/qualification.json` against current HEAD / `VERSION` file / tree-clean / both fingerprints / local image ID; presence of the local qualified image; `docker`+`gh` availability. On any failure → `die`, exit 1, **no** network writes. Produces `publish_validate <version>` and `require_tooling` functions for later tasks.

- [ ] **Step 1: Write failing tests (validation matrix)**

```bash
echo "== publish-release.sh validation gate =="
setup_pub() {   # scratch repo with a committed release + a fake qualified image
  setup_repo
  printf 'check:\n\t@true\ntest:\n\t@true\n' > Makefile
  git add -A; git commit -qm makefile; git push -q origin main
  # pin + commit like prepare would
  printf '1.3.1\n' > VERSION
  printf 'LAUNCHER_VERSION="1.3.1"\n' > bin/hdl-toolchain
  printf 'VERSION="v1.3.1"\nSHA256="x"\n' > install.sh
  printf 'VERSION="v1.3.1"\n' > uninstall.sh
  mkdir -p .out doctor container
  printf 'a\n' > versions.yml; printf 'b\n' > Containerfile; printf 'c\n' > requirements.txt
  git add -A; git commit -qm "release: v1.3.1"
  HEAD_SHA="$(git rev-parse HEAD)"
  . scripts/release_lib.sh
  IMG_ID="sha256:$(printf '%s' fixed | sha256sum | cut -c1-64)"
  # docker stub returns IMG_ID for `image inspect --format {{.Id}} hdl-course-toolchain:latest`
  cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"image inspect"*) exit 1 ;;
  *"imagetools inspect"*) exit 1 ;;
  "info") exit 0 ;;
  *) exit 0 ;;
esac
S
  chmod +x "$WORK/stub/docker"
  python3 scripts/qualification.py record --out .out/qualification.json \
    --version v1.3.1 --source-commit "$HEAD_SHA" --tree-clean 1 \
    --build-inputs-sha256 "$(build_inputs_fingerprint)" \
    --release-inputs-sha256 "$(release_inputs_fingerprint)" \
    --docker-image-ref hdl-course-toolchain:latest --docker-image-id "$IMG_ID" \
    --sif-path .out/x.sif --sif-sha256 deadbeef --platform linux/amd64 --arch x86_64 \
    --doctor-docker pass --doctor-apptainer pass
}

# 8a: clean state validates OK (stops before any push once Task 8 is all there is)
setup_pub
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; has "validation passes" "$out" "qualification: record matches"
teardown_repo

# 8b: arg != record
setup_pub
out="$(bash scripts/publish-release.sh v9.9.9 2>&1)"; neq0 "version arg mismatch rejected" "$?"
teardown_repo

# 8c: HEAD moved
setup_pub
git commit -q --allow-empty -m drift
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "HEAD moved rejected" "$?"
has "HEAD moved message" "$out" "source_commit mismatch"
teardown_repo

# 8d: build inputs changed
setup_pub
printf 'CHANGED\n' >> versions.yml
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "build inputs changed rejected" "$?"
teardown_repo

# 8e: release inputs changed
setup_pub
printf 'x\n' >> uninstall.sh
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "release inputs changed rejected" "$?"
teardown_repo

# 8f: wrong local image id
setup_pub
cat > "$WORK/stub/docker" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "sha256:0000"; exit 0 ;;
  "info") exit 0 ;; *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "wrong image id rejected" "$?"
has "image id message" "$out" "docker_image_id mismatch"
teardown_repo

# 8g: no record
setup_pub
rm -f .out/qualification.json
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "missing record rejected" "$?"
has "missing record message" "$out" "make qualify"
teardown_repo
```

- [ ] **Step 2: Run, verify fail**

Run: `bash scripts/test_release.sh`
Expected: FAIL — `publish-release.sh` missing.

- [ ] **Step 3: Implement the gate**

```bash
#!/usr/bin/env bash
# Phase 3 of a release: publish the already-qualified local image. NEVER builds.
# Resumable — safe to re-run after a network failure. See docs/releasing.md.
#
#   scripts/publish-release.sh vX.Y.Z
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
PLATFORM="$(python3 -c 'import json,sys;print(json.load(open(".out/qualification.json"))["platform"])' 2>/dev/null || echo "${PLATFORM_DEFAULT}")"

require_tooling() {
    command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
    command -v gh     >/dev/null 2>&1 || die "gh not found on PATH"
    docker info >/dev/null 2>&1 || die "docker is not running / not usable"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
}

publish_validate() {
    [ -f "${RECORD}" ] || die "no qualification record (${RECORD}) — run 'make qualify'"
    local rec_ref image_id
    rec_ref="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field docker_image_ref)"
    docker image inspect "${rec_ref}" >/dev/null 2>&1 \
        || die "the qualified image ${rec_ref} is not present locally — run 'make qualify'"
    image_id="$(docker image inspect --format '{{.Id}}' "${rec_ref}")"
    python3 "${_DIR}/qualification.py" verify \
        --record "${RECORD}" \
        --version "${VERSION}" \
        --version-file "$(cat VERSION)" \
        --head "$(git rev-parse HEAD)" \
        --tree-clean "$([ -z "$(git status --porcelain)" ] && echo 1 || echo 0)" \
        --build-inputs-sha256 "$(build_inputs_fingerprint)" \
        --release-inputs-sha256 "$(release_inputs_fingerprint)" \
        --image-id "${image_id}" \
        || die "qualification does not match the current tree/image — re-run 'make qualify'"
}

main() {
    publish_validate
    require_tooling
    echo "publish: validation OK — ${VERSION} @ $(git rev-parse --short HEAD)"
    # Tasks 9–12 add: versioned push, :latest, tag, GitHub Release.
}

main "$@"
```

Note: `qualification.py verify` compares `--version` and `--version-file` both to `record["version"]`, so 8b (`v9.9.9` arg) and a changed `VERSION` file are both caught here.

- [ ] **Step 4: Run tests, verify pass**

Run: `bash scripts/test_release.sh && shellcheck -S warning scripts/publish-release.sh`
Expected: PASS + clean shellcheck.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish-release.sh scripts/test_release.sh
git commit -m "feat: publish-release.sh validation gate and tooling check"
```

---

## Task 9: `publish-release.sh` — versioned GHCR push + resume + `.out/publish.json`

**Files:**
- Modify: `scripts/publish-release.sh`
- Modify: `scripts/test_release.sh`

**Interfaces:**
- Consumes: `publish_validate`, `require_tooling`; `remote_image_id`, `ghcr_manifest_digest`, `ghcr_ref` from `release_lib.sh`.
- Produces:
  - `.out/publish.json` = `{"version","source_commit","image_digest","versioned_ref","latest_moved":false,"tag_published":false,"release_created":false,"updated_at"}` after the versioned image is confirmed published.
  - function `ledger_set <key> <json-value>` (rewrites `.out/publish.json` via a `python3 -c` one-liner).
  - function `publish_versioned_image` implementing the three-state logic:
    - digest absent (`ghcr_manifest_digest` fails) → `docker tag <image_id> <ref>` ; `docker push <ref>` ; read digest; write ledger.
    - digest present and equals `.out/publish.json` `image_digest` → log "already published", continue.
    - digest present, no/again ledger → `remote_image_id <version> <platform>`; if it equals the record's `docker_image_id` → adopt digest into ledger, continue; else `die` "already published with a different image — versioned releases are immutable".
    - digest present but image cannot be pulled/inspected → `die` "cannot prove the published :vX.Y.Z is the qualified image".

- [ ] **Step 1: Write failing tests**

```bash
echo "== publish: versioned image =="
# 9a: fresh push
setup_pub
DIGEST="sha256:$(printf pushdigest | sha256sum | cut -c1-64)"
cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
log="$WORK/docker.log"; echo "\$*" >> "\$log"
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"image inspect"*) exit 0 ;;
  "info") exit 0 ;;
  *"buildx imagetools inspect"*) exit 1 ;;      # :v1.3.1 absent
  "tag "*) exit 0 ;;
  "push "*) exit 0 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
# after push, the digest probe must succeed — swap stub via a marker file
cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
log="$WORK/docker.log"; echo "\$*" >> "\$log"
pushed="$WORK/pushed"
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"buildx imagetools inspect"*) [ -f "\$pushed" ] && { echo '{{json .Manifest.Digest}}' >/dev/null; echo "\"${DIGEST}\""; exit 0; } || exit 1 ;;
  "push "*) touch "\$pushed"; exit 0 ;;
  "tag "*) exit 0 ;; "info") exit 0 ;; *"image inspect"*) exit 0 ;; *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"
grep -q "push ghcr.io/esd-univr/hdl-course-toolchain:v1.3.1" "$WORK/docker.log" && ok || bad "versioned push happened"
eq "ledger digest" "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["image_digest"])')" "$DIGEST"
teardown_repo

# 9b: resume — :v1.3.1 already present with the SAME image id → continue, no re-push
setup_pub
cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
log="$WORK/docker.log"; echo "\$*" >> "\$log"
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"image inspect --format {{.Id}} ghcr"*) echo "${IMG_ID}"; exit 0 ;;
  *"buildx imagetools inspect"*) echo "\"${DIGEST}\""; exit 0 ;;
  "pull "*) exit 0 ;; "tag "*) exit 0 ;; "info") exit 0 ;; *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"
grep -q "^push ghcr.*:v1.3.1" "$WORK/docker.log" && bad "should NOT re-push" || ok
has "resume message" "$out" "already published"
teardown_repo

# 9c: conflict — :v1.3.1 present with a DIFFERENT image id → abort
setup_pub
cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"image inspect --format {{.Id}} ghcr"*) echo "sha256:different"; exit 0 ;;
  *"buildx imagetools inspect"*) echo "\"${DIGEST}\""; exit 0 ;;
  "pull "*) exit 0 ;; "info") exit 0 ;; *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "immutable conflict aborts" "$?"
has "immutable message" "$out" "immutable"
teardown_repo
```

- [ ] **Step 2: Run, verify fail**

Run: `bash scripts/test_release.sh`
Expected: FAIL — no versioned push happens.

- [ ] **Step 3: Implement**

```bash
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

ledger_get() { python3 -c 'import json,sys;print(json.load(open(".out/publish.json")).get(sys.argv[1]) or "")' "$1" 2>/dev/null || true; }

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
        # Prove the remote image IS the qualified image.
        if ! remote_id="$(remote_image_id "${VERSION}" "${PLATFORM}")"; then
            die "${ref} exists but cannot be pulled/inspected — cannot prove it is the qualified image"
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
        die "push to ${ref} failed. If this is an authorization error:
  gh auth refresh -s write:packages
  gh auth token | docker login ghcr.io -u <github-user> --password-stdin
then re-run: make publish VERSION=${VERSION}"
    fi
    live_digest="$(ghcr_manifest_digest "${VERSION}")" || die "pushed ${ref} but cannot read its digest back"
    ledger_set image_digest "${live_digest}"
    echo "publish: published ${ref} @ ${live_digest}"
}
```

Call `publish_versioned_image` from `main()` after `require_tooling`.

- [ ] **Step 4: Run tests, verify pass**

Run: `bash scripts/test_release.sh && shellcheck -S warning scripts/publish-release.sh`
Expected: PASS + clean shellcheck.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish-release.sh scripts/test_release.sh
git commit -m "feat: publish versioned GHCR image, resumable via .out/publish.json"
```

---

## Task 10: `publish-release.sh` — move `:latest` after the versioned image is safe

**Files:**
- Modify: `scripts/publish-release.sh`
- Modify: `scripts/test_release.sh`

**Interfaces:**
- Consumes: `.out/publish.json` `image_digest`, `versioned_ref`; `ghcr_manifest_digest`.
- Produces: `publish_move_latest` — runs only when ledger `image_digest` is set; if `:latest` already resolves to `image_digest` → skip; else `docker tag <versioned_ref> <base>:latest` ; `docker push <base>:latest` ; verify `ghcr_manifest_digest`-of-`latest` (probe `<base>:latest`) equals `image_digest`; set ledger `latest_moved true`.

- [ ] **Step 1: Write failing tests**

```bash
echo "== publish: move :latest =="
# 10a: moves latest and verifies equality
setup_pub
DIGEST="sha256:$(printf d10 | sha256sum | cut -c1-64)"
cat > "$WORK/stub/docker" <<S
#!/usr/bin/env bash
log="$WORK/docker.log"; echo "\$*" >> "\$log"; pushed="$WORK/pushed"; lat="$WORK/lat"
case "\$*" in
  *"image inspect --format {{.Id}} hdl-course-toolchain:latest"*) echo "${IMG_ID}"; exit 0 ;;
  *"buildx imagetools inspect ghcr.io/esd-univr/hdl-course-toolchain:v1.3.1"*) [ -f "\$pushed" ] && { echo "\"${DIGEST}\""; exit 0; } || exit 1 ;;
  *"buildx imagetools inspect ghcr.io/esd-univr/hdl-course-toolchain:latest"*) [ -f "\$lat" ] && { echo "\"${DIGEST}\""; exit 0; } || exit 1 ;;
  "push ghcr.io/esd-univr/hdl-course-toolchain:v1.3.1") touch "\$pushed"; exit 0 ;;
  "push ghcr.io/esd-univr/hdl-course-toolchain:latest") touch "\$lat"; exit 0 ;;
  "tag "*) exit 0 ;; "info") exit 0 ;; *"image inspect"*) exit 0 ;; *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/docker"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"
grep -q "push ghcr.io/esd-univr/hdl-course-toolchain:latest" "$WORK/docker.log" && ok || bad ":latest pushed"
eq "ledger latest_moved" "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["latest_moved"])')" "True"
# ordering: v1.3.1 push logged before latest push
vln=$(grep -n "push .*:v1.3.1" "$WORK/docker.log" | head -1 | cut -d: -f1)
lln=$(grep -n "push .*:latest" "$WORK/docker.log" | head -1 | cut -d: -f1)
[ "$vln" -lt "$lln" ] && ok || bad ":v1.3.1 pushed before :latest"
teardown_repo

# 10b: resume — latest already at the digest → no second push
setup_pub
# (ledger pre-seeded with image_digest + latest already returning DIGEST)
teardown_repo
```

- [ ] **Step 2: Run, verify fail**

Run: `bash scripts/test_release.sh`
Expected: FAIL — `:latest` never pushed.

- [ ] **Step 3: Implement**

```bash
publish_move_latest() {
    local digest latest_ref live
    digest="$(ledger_get image_digest)"
    [ -n "${digest}" ] || die "internal: move_latest called before the versioned image was published"
    latest_ref="${IMAGE_BASE}:latest"

    if live="$(docker buildx imagetools inspect "${latest_ref}" --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"')" \
        && [ "${live}" = "${digest}" ]; then
        echo "publish: ${latest_ref} already at ${digest}"
        ledger_set latest_moved true
        return 0
    fi

    echo "publish: moving ${latest_ref} to this release"
    docker tag "$(ghcr_ref "${VERSION}")" "${latest_ref}"
    docker push "${latest_ref}" || die "push to ${latest_ref} failed — re-run: make publish VERSION=${VERSION}"
    live="$(docker buildx imagetools inspect "${latest_ref}" --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"')"
    [ "${live}" = "${digest}" ] || die "${latest_ref} resolved to ${live}, expected ${digest}"
    ledger_set latest_moved true
    echo "publish: ${latest_ref} -> ${digest}"
}
```

Call after `publish_versioned_image`.

- [ ] **Step 4: Run tests, verify pass**

Run: `bash scripts/test_release.sh && shellcheck -S warning scripts/publish-release.sh`
Expected: PASS + clean shellcheck.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish-release.sh scripts/test_release.sh
git commit -m "feat: publish moves :latest only after the versioned image is published"
```

---

## Task 11: `publish-release.sh` — annotated git tag on the qualified commit

**Files:**
- Modify: `scripts/publish-release.sh`
- Modify: `scripts/test_release.sh`

**Interfaces:**
- Consumes: `.out/qualification.json` `source_commit`; `origin_tag_object_sha`.
- Produces: `publish_tag` —
  - local tag absent → `git tag -a <version> -m "hdl-course-toolchain <version>" <source_commit>`.
  - local tag present & at `source_commit` → continue; elsewhere → `die`.
  - origin tag absent → `git push origin refs/tags/<version>` (fallback `gh api -X POST repos/<REPO>/git/refs -f ref=refs/tags/<version> -f sha=<annotated-tag-obj>` if push fails — but prefer `git push`).
  - origin tag present & resolves to `source_commit` → continue; elsewhere → `die`.
  - set ledger `tag_published true`.

- [ ] **Step 1: Write failing tests**

```bash
echo "== publish: git tag =="
# 11a: creates + pushes the tag on the qualified commit
setup_pub
# ... docker stub as in 10a (latest fully moves) ...
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"
eq "local tag on HEAD" "$(git rev-parse v1.3.1^{commit})" "$(git rev-parse HEAD)"
eq "origin has the tag" "$(git -C "$WORK/up.git" rev-parse v1.3.1^{commit})" "$(git rev-parse HEAD)"
eq "ledger tag_published" "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["tag_published"])')" "True"
teardown_repo

# 11b: resume — tag already on the right commit → continue
setup_pub
git tag -a v1.3.1 -m x
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "resume with existing correct tag OK" "$?" "0"
teardown_repo

# 11c: conflict — tag exists elsewhere → abort
setup_pub
git tag -a v1.3.1 -m x HEAD~1
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "wrong tag aborts" "$?"
has "wrong tag message" "$out" "points at"
teardown_repo
```

Note: for 11a the `gh` stub must report the origin tag absent until `git push origin refs/tags/v1.3.1` has run. Simplest: have the stub shell out to `git -C "$WORK/up.git" rev-parse` — i.e. answer from the real bare repo:

```bash
cat > "$WORK/stub/gh" <<S
#!/usr/bin/env bash
case "\$*" in
  *"release view"*) exit 1 ;;
  *"git/ref/tags/"*)
     t="\${*##*/}"
     if git -C "$WORK/up.git" rev-parse "refs/tags/\$t" >/dev/null 2>&1; then
       sha=\$(git -C "$WORK/up.git" rev-parse "refs/tags/\$t")
       printf '{"ref":"refs/tags/%s","object":{"type":"commit","sha":"%s"}}\n' "\$t" "\$sha"; exit 0
     fi
     echo '{"message":"Not Found"}'; exit 1 ;;
  *"release create"*) echo created ;;
  *) exit 0 ;;
esac
S
```

- [ ] **Step 2: Run, verify fail**

Run: `bash scripts/test_release.sh`
Expected: FAIL — no tag created.

- [ ] **Step 3: Implement**

```bash
publish_tag() {
    local want local_sha origin_sha
    want="$(python3 "${_DIR}/qualification.py" get --record "${RECORD}" --field source_commit)"

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
```

Call after `publish_move_latest`.

- [ ] **Step 4: Run tests, verify pass**

Run: `bash scripts/test_release.sh && shellcheck -S warning scripts/publish-release.sh`
Expected: PASS + clean shellcheck.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish-release.sh scripts/test_release.sh
git commit -m "feat: publish creates the annotated tag on the qualified commit"
```

---

## Task 12: `publish-release.sh` — GitHub Release with assets + notes

**Files:**
- Modify: `scripts/publish-release.sh`
- Modify: `scripts/test_release.sh`

**Interfaces:**
- Consumes: ledger `image_digest`; `qualification.py get` for note fields.
- Produces: `publish_release_notes` (writes `.out/dist/NOTES.md`) and `publish_github_release`:
  - assemble `.out/dist/` = `hdl-toolchain` (from `bin/hdl-toolchain`), `install.sh`, `uninstall.sh`, and `SHA256SUMS` = `sha256sum` of those three (run inside `.out/dist`, filenames only).
  - `gh release view <version>` fails → `gh release create <version> --verify-tag --title "hdl-course-toolchain <version>" --notes-file .out/dist/NOTES.md .out/dist/hdl-toolchain .out/dist/install.sh .out/dist/uninstall.sh .out/dist/SHA256SUMS`.
  - `gh release view` succeeds → require it is on tag `<version>` (`gh release view <version> --json tagName --jq .tagName` == `<version>`); if so → log "already created", continue; else → `die`.
  - set ledger `release_created true`; print the release URL.
- Notes contain: `source commit`, `architecture`, `ghcr.io/esd-univr/hdl-course-toolchain:<version>`, the `@sha256:` digest, "`:latest` was moved to this release", and a qualification summary line (`doctor_docker`/`doctor_apptainer`/`build_inputs_sha256`/`qualified_at`).

- [ ] **Step 1: Write failing tests**

```bash
echo "== publish: GitHub Release =="
setup_pub
# docker stub: full happy path (v1.3.1 + latest resolve to DIGEST after push)
# gh stub: release view fails until `release create` writes a marker; then returns tagName v1.3.1
cat > "$WORK/stub/gh" <<S
#!/usr/bin/env bash
mk="$WORK/rel"
case "\$*" in
  *"release view"*) [ -f "\$mk" ] || exit 1
     case "\$*" in *"--json tagName"*) echo '{"tagName":"v1.3.1"}';; *) echo release;; esac; exit 0 ;;
  *"release create"*) touch "\$mk"; echo "https://github.com/esd-univr/hdl-course-toolchain/releases/tag/v1.3.1"; exit 0 ;;
  *"git/ref/tags/"*)
     t="\${*##*/}"; git -C "$WORK/up.git" rev-parse "refs/tags/\$t" >/dev/null 2>&1 || { echo '{"message":"Not Found"}'; exit 1; }
     sha=\$(git -C "$WORK/up.git" rev-parse "refs/tags/\$t"); printf '{"object":{"type":"commit","sha":"%s"}}\n' "\$sha"; exit 0 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/gh"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "publish exits 0" "$?" "0"
test -f .out/dist/SHA256SUMS && ok || bad "SHA256SUMS assembled"
grep -q 'hdl-toolchain$' .out/dist/SHA256SUMS && ok || bad "SHA256SUMS lists hdl-toolchain"
grep -q 'SHA256SUMS' .out/dist/SHA256SUMS && bad "SHA256SUMS must not checksum itself" || ok
has "notes carry the digest" "$(cat .out/dist/NOTES.md)" "sha256:"
has "notes say latest moved" "$(cat .out/dist/NOTES.md)" "latest"
eq "ledger release_created" "$(python3 -c 'import json;print(json.load(open(".out/publish.json"))["release_created"])')" "True"
# full resume: re-run is a clean no-op
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; eq "resume exits 0" "$?" "0"
has "resume notes release exists" "$out" "already"
teardown_repo

# 12b: release exists on a different tag → abort
setup_pub
cat > "$WORK/stub/gh" <<'S'
#!/usr/bin/env bash
case "$*" in
  *"release view"*) case "$*" in *"--json tagName"*) echo '{"tagName":"v9.9.9"}';; *) echo r;; esac; exit 0 ;;
  *"git/ref/tags/"*) echo '{"message":"Not Found"}'; exit 1 ;;
  *) exit 0 ;;
esac
S
chmod +x "$WORK/stub/gh"
out="$(bash scripts/publish-release.sh v1.3.1 2>&1)"; neq0 "release on wrong tag aborts" "$?"
teardown_repo
```

- [ ] **Step 2: Run, verify fail**

Run: `bash scripts/test_release.sh`
Expected: FAIL — no release created.

- [ ] **Step 3: Implement**

```bash
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
        echo "publish: GitHub Release ${VERSION} already exists — leaving it as-is"
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
```

Call both (`publish_github_release` calls `publish_release_notes`) after `publish_tag`. End `main()` with a short summary reading the ledger.

- [ ] **Step 4: Run tests, verify pass**

Run: `bash scripts/test_release.sh && shellcheck -S warning scripts/publish-release.sh`
Expected: PASS + clean shellcheck.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish-release.sh scripts/test_release.sh
git commit -m "feat: publish creates the GitHub Release with assets and qualification notes"
```

---

## Task 13: Makefile `prepare` / `publish` targets; retire `release`; `scripts/release.sh` removed

**Files:**
- Modify: `Makefile`
- Delete: `scripts/release.sh`
- Modify: `scripts/test_release.sh` (grep guard)

**Interfaces:**
- Produces: `make prepare VERSION=vX.Y.Z` → `scripts/prepare-release.sh`; `make publish VERSION=vX.Y.Z` → `scripts/publish-release.sh`; `make release` → prints the new flow and exits non-zero.

- [ ] **Step 1: Write the failing guard test**

```bash
echo "== machinery wiring =="
( cd "$ROOT"
  make -n prepare VERSION=v1.3.1 >/dev/null 2>&1 && ok || bad "make prepare target exists"
  make -n publish VERSION=v1.3.1 >/dev/null 2>&1 && ok || bad "make publish target exists"
  out="$(make release 2>&1 || true)"; has "make release points at new flow" "$out" "make prepare"
  test ! -e scripts/release.sh && ok || bad "scripts/release.sh removed"
  grep -q 'scripts/prepare-release.sh' Makefile && ok || bad "Makefile calls prepare-release.sh"
)
```

- [ ] **Step 2: Run, verify fail**

Run: `bash scripts/test_release.sh`
Expected: FAIL — targets missing / `release.sh` present.

- [ ] **Step 3: Implement**

In `Makefile`, update `.PHONY`, replace the `release:` target, add `prepare` and `publish`:

```make
.PHONY: help software check test updates bump fetch build doctor doctor-sif shell export sif qualify prepare publish release clean

prepare: ## Pin a version and commit "release: vX.Y.Z": make prepare VERSION=vX.Y.Z
	@test -n "$(VERSION)" || { printf 'usage: make prepare VERSION=vX.Y.Z\n' >&2; exit 2; }
	@./scripts/prepare-release.sh "$(VERSION)"

publish: ## Publish the already-qualified image + tag + Release: make publish VERSION=vX.Y.Z
	@test -n "$(VERSION)" || { printf 'usage: make publish VERSION=vX.Y.Z\n' >&2; exit 2; }
	@./scripts/publish-release.sh "$(VERSION)"

release: ## Removed — use prepare -> qualify -> publish
	@printf 'make release was removed. The flow is now:\n\n' >&2
	@printf '  make prepare VERSION=vX.Y.Z\n  make qualify\n  make publish VERSION=vX.Y.Z\n\n' >&2
	@printf 'See docs/releasing.md.\n' >&2
	@exit 2
```

Update the `help` target text: drop the `make release` line, add:

```make
	@printf '  make prepare   Pin a version and commit the release commit: make prepare VERSION=vX.Y.Z\n'
	@printf '  make qualify   Full local qualification; writes .out/qualification.json\n'
	@printf '  make publish   Publish the qualified image, tag and GitHub Release: make publish VERSION=vX.Y.Z\n'
```

Then:

```bash
git rm scripts/release.sh
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bash scripts/test_release.sh && make -n prepare VERSION=v1.3.1 && make -n publish VERSION=v1.3.1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Makefile scripts/test_release.sh
git rm scripts/release.sh
git commit -m "feat: make prepare/publish targets; retire make release and scripts/release.sh"
```

---

## Task 14: Delete `release.yml`; add the workflow guard test; wire `test_release.sh` into `make test`

**Files:**
- Delete: `.github/workflows/release.yml`
- Modify: `Makefile` (`test` target)
- Modify: `scripts/test_release.sh` (workflow guard)

**Interfaces:**
- Produces: no workflow triggers on tags or runs `make build`/`make fetch`; `make test` runs `scripts/test_release.sh`.

- [ ] **Step 1: Write the failing guard test**

```bash
echo "== workflows are lightweight only =="
( cd "$ROOT"
  test ! -e .github/workflows/release.yml && ok || bad "release.yml deleted"
  if grep -rnE 'tags:|make build|make fetch|ghcr\.io|docker push' .github/workflows/ ; then
    bad "a workflow still references heavyweight release steps"
  else ok; fi
  grep -q 'test_release.sh' Makefile && ok || bad "make test runs test_release.sh"
)
```

- [ ] **Step 2: Run, verify fail**

Run: `bash scripts/test_release.sh`
Expected: FAIL — `release.yml` still present.

- [ ] **Step 3: Implement**

```bash
git rm .github/workflows/release.yml
```

In `Makefile` `test:` target, append:

```make
	@printf '\n==> release machinery tests\n'
	@bash scripts/test_release.sh
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bash scripts/test_release.sh && make test`
Expected: PASS; `make test` now also runs the release suite.

- [ ] **Step 5: Commit**

```bash
git add Makefile scripts/test_release.sh
git rm .github/workflows/release.yml
git commit -m "chore: delete the heavyweight release workflow; run release tests in make test"
```

---

## Task 15: Rewrite `docs/releasing.md`

**Files:**
- Modify: `docs/releasing.md` (full rewrite)

**Interfaces:** none (documentation).

- [ ] **Step 1: Rewrite the file**

Replace the whole file with a runbook covering, in order:

1. **What a release publishes** — the table (`:vX.Y.Z` immutable, `:latest` moving, GitHub Release with the four assets). Keep the "toolchain-release qualification ≠ course/lesson qualification" note.
2. **Three roles** —
   ```
   GitHub Actions      = lightweight repository CI (make check, make test, shellcheck)
   maintainer workstation = heavy toolchain build + qualification + OCI publication
   GitHub / GHCR       = distribution
   ```
   Explicit: pushing a tag does **not** trigger an image build.
3. **One-time GHCR authentication** —
   ```bash
   gh auth refresh -s write:packages,read:packages
   gh auth token | docker login ghcr.io -u <github-user> --password-stdin
   ```
   Note the default `gh` token lacks `packages` scope; `make publish` stops with these commands if the push is unauthorized.
4. **The flow** —
   ```bash
   git switch main && git pull
   make prepare VERSION=vX.Y.Z    # pins + commits "release: vX.Y.Z"; nothing else
   make qualify                   # builds, both doctors, writes .out/qualification.json
   make publish VERSION=vX.Y.Z    # validates the record, pushes :vX.Y.Z, moves :latest, tags, cuts the Release
   ```
   Describe each phase's preconditions and outputs (from spec §4).
5. **The qualification record** — what `.out/qualification.json` binds (`docker_image_id`, `source_commit`, `VERSION`, `build_inputs_sha256`, `release_inputs_sha256`) and the exact reasons `make publish` aborts (spec §4.3 table).
6. **Resuming a failed publish** — `.out/publish.json`; the three-state rule; the worked example (`:vX.Y.Z` ok, `:latest` failed → just re-run `make publish VERSION=vX.Y.Z`); versioned image / tag / release conflicts abort, never overwrite.
7. **Choosing the version** — patch/minor/major intent (keep from the old doc); `v1.0.0`–`v1.2.0` spent; `v1.3.x` is the GHCR-image + installer model; nothing was ever published for `v1.3.0`.
8. **Verify from scratch** — the throwaway-`HOME` install test + `docker buildx imagetools inspect` digest cross-check (keep from the old doc).
9. **Adopting it in the courses** — unchanged: each course qualifies against `…:vX.Y.Z@sha256:…` in its own repo; publishing the image qualifies no course.

Remove every mention of `release.yml`, "pushing the tag triggers", `gh run watch … release.yml`, and self-hosted runners.

- [ ] **Step 2: Check links + references**

Run:
```bash
grep -nE 'release\.yml|pushing the tag|self-hosted|gh run watch' docs/releasing.md && echo BAD || echo OK
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add docs/releasing.md
git commit -m "docs: rewrite releasing.md around local prepare/qualify/publish"
```

---

## Task 16: Update `docs/architecture.md` and `README.md`

**Files:**
- Modify: `docs/architecture.md` ("Distribution" section)
- Modify: `README.md` (~line 50 and ~line 108)

- [ ] **Step 1: `docs/architecture.md` — replace the Distribution diagram**

Replace the `tag vX.Y.Z ──> .github/workflows/release.yml ...` block and the paragraph after it with:

```text
maintainer workstation
    make qualify   → local OCI image + .out/qualification.json  (build-input + image-ID bound to HEAD)
    make publish   → ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z   (immutable)
                   → ghcr.io/esd-univr/hdl-course-toolchain:latest    (moved per release)
                   → GitHub Release vX.Y.Z: hdl-toolchain, install.sh, uninstall.sh, SHA256SUMS

GitHub Actions = lightweight repository CI only (make check, make test, shellcheck)
GitHub / GHCR  = distribution
```

Update the trailing sentences: `scripts/prepare-release.sh` does the git half (version pin + `release:` commit); `make qualify` builds and records; `scripts/publish-release.sh` publishes the *already-qualified* image without rebuilding. The versioned tag is never rewritten; `publish` refuses a version that already has an image, tag or release. Runbook: `releasing.md`.

- [ ] **Step 2: `README.md`**

- ~line 50: keep the bullet describing the `:vX.Y.Z` / `:latest` / Release assets, but drop any implication that CI builds them. If the surrounding prose says "Each release publishes", leave it; it's accurate.
- ~line 108: keep "See [`docs/releasing.md`](docs/releasing.md) for how a release is cut." — still correct.
- Search for stale mentions:
  ```bash
  grep -nE 'workflow|Actions|CI build|tag.*trigger' README.md
  ```
  Fix any that claim CI builds or publishes the image. (The `make` quick-start section needs no change.)

- [ ] **Step 3: Check `scripts/*.sh` header comments**

Run:
```bash
grep -rn 'release\.yml\|CI builds\|pushing.*tag.*triggers' scripts/ *.md docs/
```
Fix any remaining stale references (e.g. leftover comments). Expected after fixing: no hits outside the design/plan docs and `docs/releasing.md`'s explicit "no longer" wording.

- [ ] **Step 4: Commit**

```bash
git add docs/architecture.md README.md scripts/
git commit -m "docs: architecture + README reflect local build/qualify/publish"
```

---

## Task 17: Full self-review pass and green-suite verification

**Files:** none (verification only); fix-forward commits if gaps found.

- [ ] **Step 1: Run the whole fast suite**

Run:
```bash
make check
make test          # includes scripts/test_release.sh
shellcheck -S warning bin/hdl-toolchain install.sh uninstall.sh scripts/*.sh
python3 -m unittest discover -s scripts -v
```
Expected: all green. Fix any failure before continuing.

- [ ] **Step 2: Spec-coverage checklist**

Walk `docs/superpowers/specs/2026-09-09-local-release-machinery-design.md` section by section and confirm a task covers each:

- §3 cleanup + §3.3 rebase → Task 1
- §4.1 prepare (preconditions incl. exact `origin/main`, idempotent resume, dev sentinel) → Tasks 6–7
- §4.2 qualify (stale-record delete, clean-tree gate before build, record only on success + still-clean) → Task 5
- §4.3 publish validation gate (all rows of the table) → Task 8
- §5 record schema/fields → Tasks 2–3, 5
- §6 resume ledger + three-state rule + image-`.Id` proof for an existing `:vX.Y.Z` → Tasks 9–12
- §7 GHCR auth message, no throwaway artifacts → Tasks 8–9
- §8 `:latest` after versioned → Task 10
- §9 workflows → Task 14
- §10 docs → Tasks 15–16
- §11 test matrix → Tasks 6–12 tests + Task 14 guard
- §12 out-of-scope untouched → grep check below

List any gap and add a task for it.

- [ ] **Step 3: Out-of-scope guard**

Run:
```bash
git diff --stat main...HEAD -- \
  ':(exclude)Makefile' ':(exclude)scripts/*' ':(exclude).github/*' \
  ':(exclude)docs/*' ':(exclude)README.md' ':(exclude)VERSION' \
  ':(exclude)bin/hdl-toolchain' ':(exclude)install.sh' ':(exclude)uninstall.sh'
```
Expected: empty (nothing outside the intended surface changed). `versions.yml`, `Containerfile`, `configure.py`, `versions.py` must not appear.

- [ ] **Step 4: Confirm the premature commits cannot return**

Run:
```bash
git merge-base --is-ancestor 30cb593 HEAD && echo BAD || echo OK
git merge-base --is-ancestor 6805fa1 HEAD && echo BAD || echo OK
git log --oneline main..HEAD | grep -i 'release: v1.3' && echo BAD || echo OK
```
Expected: three `OK`.

- [ ] **Step 5: Commit any fixes, then stop for review**

```bash
git add -A && git commit -m "chore: self-review fixes" || true
```

Report to the maintainer: branch `feature/local-release-machinery` ready; what was tested with stubs vs. what needs the real `make prepare`/`make qualify`/`make publish` with credentials (spec §11).

---

## Self-Review (plan author)

**Spec coverage:** every spec section maps to a task — see Task 17 Step 2. The cleanup (§3) and the feature-branch rebase (§3.3) are Task 1; the six spec amendments are folded into Tasks 5 (clean-tree gate), 8 (version-file check), 9 (image-`.Id` proof), 6 (exact `origin/main`), 1 (rebase guard), 15/17 (network wording), 12 (`SHA256SUMS`).

**Placeholder scan:** no "TBD"/"handle edge cases"/"similar to Task N". Doc tasks (15–16) specify section-by-section content rather than final prose, which is appropriate for documentation; every code task carries runnable test + implementation code.

**Type/name consistency:** `qualification.py` subcommands `record`/`verify`/`get` used identically in Tasks 2, 3, 5, 8, 9, 11, 12. Ledger keys `image_digest`, `latest_moved`, `tag_published`, `release_created` consistent across Tasks 9–12 and match spec §6. `release_lib.sh` function names (`release_inputs_fingerprint`, `build_inputs_fingerprint`, `ghcr_ref`, `ghcr_manifest_digest`, `remote_image_id`, `origin_tag_object_sha`, `gh_release_exists`, `die`) used consistently in Tasks 6–12. Record field names (`docker_image_id`, `source_commit`, `build_inputs_sha256`, `release_inputs_sha256`, `architecture`, `platform`) match spec §5.
