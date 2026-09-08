# HDL Course Toolchain

Reproducible HDL/EDA environment for digital systems, testing, and verification
courses at the University of Verona.

This repository contains shared infrastructure only. Exercises, assignment
logic, expected results, and course-specific qualification remain in the course
repositories.

## Quick start

The root `Makefile` is the supported human-facing interface. Run `make` with no
arguments to see the available commands, grouped by purpose:

```bash
make
```

Inspect the planned software inventory before building:

```bash
make software
```

The inventory is generated from [`versions.yml`](versions.yml); it is not a
second hand-maintained package list.

A typical qualification flow is:

```bash
make check
make fetch
make build
make doctor
```

Open an interactive shell in the built OCI image with:

```bash
make shell
```

The launcher mounts the selected workspace at `/work` and disables network
access by default.

## Consuming the toolchain

Students do **not** clone this repository. Each release publishes:

- an OCI image at `ghcr.io/esd-univr/hdl-course-toolchain` — immutable
  `:vX.Y.Z` tags plus a `:latest` that moves only when a new qualified release
  is published;
- the `hdl-toolchain` launcher, an `install.sh`, an `uninstall.sh` and a
  `SHA256SUMS`, as GitHub Release assets.

### Students

One-time setup:

```bash
curl -fsSL https://github.com/esd-univr/hdl-course-toolchain/releases/latest/download/install.sh | bash
```

The safer, inspect-first form:

```bash
curl -fsSL https://github.com/esd-univr/hdl-course-toolchain/releases/latest/download/install.sh -o install.sh
less install.sh && sh install.sh
```

This installs one file, `~/.local/bin/hdl-toolchain`, and adds that directory
to `PATH` if it is missing. It downloads the launcher from the Release (not from
`main`) and verifies it with SHA-256. Docker (or Docker Desktop) must already be
installed and running; the installer does not install Docker. Then, from any
lesson directory:

```bash
hdl-toolchain --workspace . -- zsh -l
```

The launcher obtains and refreshes `:latest` on its own, tolerates being
offline when a usable image is already cached, and prints the exact image
digest it runs.

To remove it, run `hdl-toolchain`'s uninstaller (it only deletes the launcher):

```bash
curl -fsSL https://github.com/esd-univr/hdl-course-toolchain/releases/latest/download/uninstall.sh | sh
```

`uninstall.sh --dry-run` shows what it would do; `uninstall.sh --purge-image`
also removes local `ghcr.io/esd-univr/hdl-course-toolchain` images (and nothing
else — it never touches Docker itself, other images, containers, or your
workspaces).

### Courses

A course qualification is tied to a specific release, pinned by digest:

```bash
hdl-toolchain --image ghcr.io/esd-univr/hdl-course-toolchain:vX.Y.Z@sha256:… --workspace . -- make
```

Course repositories keep that reference in their `toolchain-baseline.yml` and
their lesson Makefiles read it from there.

`main` is the development line for the next shared-infrastructure revision.
See [`docs/releasing.md`](docs/releasing.md) for how a release is cut.

## Waveform inspection

`vcdtui` is the required, container-native waveform viewer. It is installed as
an ordinary command on `PATH`, so a generated trace can be inspected directly:

```bash
vcdtui build/waves/example.vcd
```

Its deterministic non-interactive mode is also used by qualification:

```bash
vcdtui build/waves/example.vcd --signals clk,count --dump --ascii --no-color
```

GTKWave is not installed in the default image. Users may still open generated
VCD files with any host-side viewer they prefer; course material should use
`vcdtui` for the portable, qualified path.

## Software inventory

`versions.yml` is the single source of truth for pinned tool versions, source
commits, package versions, architecture notes, and source archive integrity.

Use:

```bash
make software
```

to render the human-readable software plan. The output is grouped using the
sections already present in `versions.yml`, shows version/source/architecture,
and omits archive-digest entries because those are integrity metadata rather
than installed software.

For the exact Debian packages resolved inside a built image, see:

```text
/opt/toolchain/report/apt-packages.txt
```

Python dependencies are separately locked in
[`requirements.txt`](requirements.txt).

## Keeping the pins current

Each software entry in `versions.yml` declares an `upstream:` field saying where
newer versions are published. To compare every pin against what upstream serves
today:

```bash
make updates
```

This is read-only and the only inventory command that uses the network. A pin to
a git commit is reported as its distance from a named branch rather than as a
version, and an entry declaring `manual` is listed as such instead of being
silently skipped. `TOOL=<name>` narrows the report to one pin.

Every run queries every upstream live, so the answer is never quietly out of
date: a release cut an hour ago is precisely the one worth seeing. The cache
under `.out/` is a fallback, not a shortcut. It is consulted only when an
upstream cannot be reached — no network, or the GitHub rate limit exhausted —
and such a row is printed as `unverified, cached 3h ago` and listed again in the
summary, rather than being passed off as current.

A full report costs about 18 requests to `api.github.com`. Unauthenticated that
allows three runs an hour, so set `GITHUB_TOKEN` to raise the limit from 60
requests/hour to 5000. The one thing remembered between runs is whether a
project pinned to a commit publishes releases at all, which feeds an advisory
line and changes on the scale of months; `REFRESH=1` re-probes those too.

To move one pin:

```bash
make bump TOOL=yosys VERSION=v0.68
make bump TOOL=yosys VERSION=v0.68 DRY_RUN=1    # verify without writing
```

`bump` rewrites the version, derives the new archive URL from it, downloads what
that URL actually serves, and records the SHA-256 it computed. If the URL cannot
be derived from the version alone it refuses and leaves the manifest untouched,
rather than writing a pin that would fail later during `make fetch`.

`bump` deliberately stops there: it does not rebuild the image and does not run
the doctor. Promoting a new pin is a qualification decision, so `make build` and
`make doctor` stay separate, deliberate steps. Prose in `notes:` is not
rewritten either — review it by hand.

## Reproducibility

The build tooling checks that every bare `ARG` consumed by `Containerfile` has a
corresponding pin in `versions.yml` and that no manifest pin is unused.
Downloaded source archives are SHA-256 verified before use.

HIF is pinned as one coordinated commit tuple across `hif-core`,
`hif-frontend`, `hif-backend`, and `hif-muffin`; each image records those exact
commits at `/opt/hif/BUILD_PINS.txt`.

HARM is likewise built from pinned source inputs and records its authoritative
build tuple at `/opt/harm/BUILD_PINS.txt`. The functional doctor exercises the
qualified Verilator VCD -> HARM -> SVA path.

Reproducibility here refers to the toolchain inputs and installed environment.
HARM v3 mining itself is not output-deterministic: identical runs may produce
different top-ranked candidate sets, including with `--max-threads 1`.
Qualification therefore checks successful mining and meaningful SVA production,
not byte-identical miner output.

`make check` performs the fast repository-level validation. It does not replace
an image build or the functional doctor.

## Docker and Apptainer

The OCI image built from `Containerfile` is the canonical installed
environment. The Apptainer SIF is derived from that OCI image rather than from a
second installation recipe.

Build the OCI image and run its functional health checks with:

```bash
make build
make doctor
```

Build the SIF with:

```bash
make sif
```

Run through either engine with the same launcher (maintainers use the in-tree
copy; students use the installed one on `PATH`):

```bash
./bin/hdl-toolchain --engine docker --workspace "$PWD" -- zsh -l
./bin/hdl-toolchain --engine apptainer --workspace "$PWD" -- zsh -l
```

With `--engine apptainer` and no `--sif`, the launcher runs the OCI image
directly (`apptainer exec docker://ghcr.io/esd-univr/hdl-course-toolchain:…`);
Apptainer pulls and caches it. `--sif PATH` still runs a locally built SIF.

The canonical qualified architecture is `linux/amd64`. The launcher passes
`--platform linux/amd64` by default (env: `HDL_TOOLCHAIN_PLATFORM`, flag:
`--platform`); on Apple Silicon this means Docker Desktop emulation, which is
the intended behaviour. `--platform native` opts out, for a maintainer building
and testing an arm64 image.

Recognised environment overrides (a misspelled `HDL_TOOLCHAIN_*` name is
rejected, not ignored):

| Variable | Flag | Meaning |
|---|---|---|
| `HDL_TOOLCHAIN_IMAGE` | `--image` | image reference; may carry its own `:tag` or `@sha256:` digest |
| `HDL_TOOLCHAIN_TAG` | `--tag` | tag to append when the reference is a bare repository |
| `HDL_TOOLCHAIN_PLATFORM` | `--platform` | container platform, default `linux/amd64`; `native` to skip |
| `HDL_TOOLCHAIN_PULL` | `--pull` | `auto` (default), `always`, or `never` |
| `HDL_TOOLCHAIN_ENGINE` | `--engine` | `docker` (default) or `apptainer` |
| `HDL_TOOLCHAIN_SIF` | `--sif` | run this SIF instead of `docker://` under Apptainer |
| `HDL_TOOLCHAIN_DOCKER` | — | Docker CLI to invoke (default `docker`) |
| `HDL_TOOLCHAIN_QUIET` | — | suppress the `[hdl-toolchain]` identity lines |

## Validation model

`toolchain-doctor` checks the installed environment and runs small functional
smoke tests where appropriate. Course repositories own the higher-level
qualification that proves their exercises work with a particular toolchain
revision.

A successful doctor means the shared environment is healthy; it does not by
itself qualify every consuming course.

Release qualification is currently performed on `linux/amd64`. Architecture
support reported by individual tools in `make software` does not imply that the
complete toolchain has been qualified on that architecture.

## Repository layout

```text
.
├── Containerfile             # canonical OCI build
├── versions.yml              # single source of truth for tool/build pins
├── VERSION                   # toolchain release version (pinned by scripts/release.sh)
├── Makefile                  # human-facing command interface
├── install.sh                # student installer, published as a Release asset
├── uninstall.sh              # conservative uninstaller, published as a Release asset
├── requirements.in           # direct Python dependencies
├── requirements.txt          # resolved Python lock
├── apptainer/                # OCI-to-SIF definition
├── bin/                      # the hdl-toolchain launcher (also a Release asset)
├── container/                # runtime shell and entrypoint
├── doctor/                   # functional health checks
├── docs/                     # architecture, releasing, and maintenance notes
└── scripts/                  # manifest, updates, fetch, build, release, tests
```

See [`docs/architecture.md`](docs/architecture.md) for the repository boundary,
build flow, and validation model.
