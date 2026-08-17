# HDL Course Toolchain

Reproducible HDL/EDA toolchain for teaching digital systems, testing, and verification courses at the University of
Verona.

The repository provides a shared execution environment for course repositories. It contains the toolchain only:
exercises, labs, and course-specific validation remain in their respective repositories.

## Goals

- provide the same HDL toolchain across different courses;
- support both Docker/OCI and Apptainer workflows;
- pin tool versions and source archives explicitly;
- avoid hidden dependencies on the host system;
- provide functional smoke tests through a common doctor;
- keep course material separate from infrastructure.

## Toolchain

The environment includes tools for simulation, synthesis, verification, testing, and implementation, including:

- Icarus Verilog
- Verilator
- Yosys
- cocotb / pytest
- Z3
- HIF and Muffin
- Fault
- Quaigh
- ngspice
- OpenROAD
- GTKWave
- Graphviz

Exact versions, source references, and archive digests are defined in [`versions.yml`](versions.yml).

## Quick start

Fetch the pinned source archives:

```bash
./scripts/fetch-sources.sh
````

Build the OCI image:

```bash
./scripts/build-image.sh
```

Run the toolchain doctor:

```bash
./bin/hdl-toolchain --workspace "$PWD" -- toolchain-doctor
```

Open an interactive shell:

```bash
./bin/hdl-toolchain --workspace "$PWD" -- zsh -l
```

The launcher mounts the selected workspace at `/work` and disables network access by default.

## Docker and Apptainer

The OCI image is the canonical toolchain definition.

The Apptainer image is derived from the same OCI artifact rather than rebuilding the environment independently. This
keeps Docker and Apptainer installations aligned.

The launcher supports both engines:

```bash
./bin/hdl-toolchain --engine docker ...
./bin/hdl-toolchain --engine apptainer ...
```

## Reproducibility

Tool versions are maintained centrally in [`versions.yml`](versions.yml).

The build infrastructure checks that:

- every build-time version argument has a corresponding pin;
- unused pins are rejected;
- downloadable source archives are SHA-256 verified;
- the manifest and `Containerfile` cannot silently drift apart.

Python dependencies are separately locked in [`requirements.txt`](requirements.txt).

## Repository layout

```text
.
├── Containerfile
├── versions.yml
├── requirements.txt
├── apptainer/      # Apptainer image definition
├── bin/            # user-facing launcher
├── container/      # runtime environment and shell setup
├── doctor/         # functional toolchain checks
└── scripts/        # build, fetch, export, and validation helpers
```

## Validation model

`toolchain-doctor` checks the installed tools and runs small functional smoke tests where appropriate.

Course repositories are responsible for their own higher-level qualification: a successful toolchain doctor means that
the environment works, not that every course exercise has been validated against that particular toolchain revision.

## Development status

The toolchain is under active development while it is being qualified against the HDL courses that consume it.

Changes to shared infrastructure should remain course-independent. Course-specific wrappers, exercises, expected
outputs, and pedagogical checks belong in the corresponding course repository.
