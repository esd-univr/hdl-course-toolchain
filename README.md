# HDL Course Toolchain

Reproducible HDL/EDA environment for digital systems, testing, and verification
courses at the University of Verona.

This repository contains shared infrastructure only. Exercises, assignment
logic, expected results, and course-specific qualification remain in the course
repositories.

## Quick start

The root `Makefile` is the supported human-facing interface:

```bash
make help
make check
make build
make doctor
```

Open an interactive shell in the built Docker image:

```bash
make shell
```

The launcher mounts the selected workspace at `/work` and disables network
access by default.

## Toolchain

The environment includes tools for simulation, synthesis, verification,
testing, and implementation, including:

- Icarus Verilog
- Verilator
- Yosys
- cocotb / pytest
- Z3
- HIF and Muffin
- Quaigh
- Fault
- ngspice
- OpenROAD
- GTKWave
- Graphviz

Exact versions, source commits, and archive digests are defined in
[`versions.yml`](versions.yml).

## Reproducibility

`versions.yml` is the source of truth for build-time pins. The build tooling
checks that every `Containerfile` version argument has a corresponding manifest
entry and that no manifest pin is unused. Downloaded source archives are
SHA-256 verified before use.

Python dependencies are separately locked in
[`requirements.txt`](requirements.txt).

HIF is pinned as one coordinated commit tuple across `hif-core`,
`hif-frontend`, `hif-backend`, and `hif-muffin`; the image records those exact
commits at `/opt/hif/BUILD_PINS.txt`.

## Docker and Apptainer

The OCI image built from `Containerfile` is the canonical installed
environment. The Apptainer SIF is derived from that OCI image rather than from a
second installation recipe.

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

A successful doctor means the environment is healthy; it does not by itself
qualify every consuming course.

## Repository layout

```text
.
├── Containerfile             # canonical OCI build
├── versions.yml              # tool and archive pins
├── Makefile                  # human-facing commands
├── requirements.in           # direct Python dependencies
├── requirements.txt          # resolved Python lock
├── apptainer/                # OCI-to-SIF definition
├── bin/                      # user-facing launcher
├── container/                # runtime shell and entrypoint
├── doctor/                   # functional health checks
├── docs/                     # architecture and maintenance notes
└── scripts/                  # build, fetch, export, and validation helpers
```

See [`docs/architecture.md`](docs/architecture.md) for the repository boundary,
build flow, and validation model.
