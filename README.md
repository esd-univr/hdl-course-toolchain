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

Course repositories should consume a qualified release of this toolchain rather
than track `main`. A course qualification is therefore associated with a
specific toolchain release and, when distributed as an OCI image, preferably an
immutable image digest.

`main` is the development line for the next shared-infrastructure revision.

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
silently skipped. Set `GITHUB_TOKEN` to raise the unauthenticated GitHub rate
limit of 60 requests/hour; responses are cached under `.out/` for six hours, and
`REFRESH=1` ignores that cache.

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

Run through either engine with the same launcher:

```bash
./bin/hdl-toolchain --engine docker --workspace "$PWD" -- zsh -l
./bin/hdl-toolchain --engine apptainer --workspace "$PWD" -- zsh -l
```

Environment overrides use the `HDL_TOOLCHAIN_*` prefix, including
`HDL_TOOLCHAIN_IMAGE`, `HDL_TOOLCHAIN_TAG`, `HDL_TOOLCHAIN_PLATFORM`,
`HDL_TOOLCHAIN_ENGINE`, and `HDL_TOOLCHAIN_SIF`.

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
├── Makefile                  # human-facing command interface
├── requirements.in           # direct Python dependencies
├── requirements.txt          # resolved Python lock
├── apptainer/                # OCI-to-SIF definition
├── bin/                      # user-facing launcher
├── container/                # runtime shell and entrypoint
├── doctor/                   # functional health checks
├── docs/                     # architecture and maintenance notes
└── scripts/                  # manifest, updates, fetch, build, export, validation
```

See [`docs/architecture.md`](docs/architecture.md) for the repository boundary,
build flow, and validation model.
