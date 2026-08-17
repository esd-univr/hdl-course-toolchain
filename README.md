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

## Reproducibility

The build tooling checks that every bare `ARG` consumed by `Containerfile` has a
corresponding pin in `versions.yml` and that no manifest pin is unused.
Downloaded source archives are SHA-256 verified before use.

HIF is pinned as one coordinated commit tuple across `hif-core`,
`hif-frontend`, `hif-backend`, and `hif-muffin`; each image records those exact
commits at `/opt/hif/BUILD_PINS.txt`.

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
└── scripts/                  # manifest, fetch, build, export, validation
```

See [`docs/architecture.md`](docs/architecture.md) for the repository boundary,
build flow, and validation model.
