# Architecture

This repository owns the shared execution environment used by HDL teaching
repositories. It does not own exercises, expected results, assignment logic, or
course-specific qualification.

## Source of truth

The build has one canonical path:

```text
versions.yml
    |
    v
scripts/fetch-sources.sh
    |
    v
Containerfile  --->  OCI image  --->  Apptainer SIF
    |
    v
toolchain-doctor
```

`versions.yml` is the source of truth for build-time pins and downloadable
artifact digests. `scripts/versions.py` enforces a one-to-one relationship
between manifest pins and `Containerfile` ARGs.

The OCI image is the canonical installed environment. The Apptainer SIF is
derived from that image rather than built from a second installation recipe.

## Moving a pin

Pins are not edited by hand. `scripts/configure.py` owns both directions:

```text
upstream (GitHub, crates.io, Ubuntu archive)
    |
    v
make updates            read-only: what is pinned vs what upstream publishes
    |
    v
make bump TOOL=.. VERSION=..
    |
    v
versions.yml            version, archive_url and SHA-256 rewritten together
```

Each software entry declares an `upstream:` field naming where newer versions
are published, because the question differs by pin kind: a tag pin is compared
against the latest release or tag, a commit pin is reported as its distance
from a named branch, and `manual` marks a pin with no machine-readable source
so it stays visible rather than silently unchecked. A commit pin on a project
that does publish releases is reported as needing attention.

`bump` derives the new archive URL from the version, downloads what that URL
actually serves, and records the digest it computed. If the URL cannot be
derived by substitution it refuses and leaves the manifest untouched, so a pin
that would fail during `make fetch` is never written.

`bump` stops at the manifest. It does not rebuild the image and does not run
the doctor: adopting a new pin is a qualification decision, so `make build` and
`make doctor` remain separate deliberate steps.

## HIF baseline

HIF is treated as a coordinated multi-repository dependency. `hif-core`,
`hif-frontend`, `hif-backend`, and `hif-muffin` are pinned as one tested commit
tuple, with the corresponding GitHub source archives pinned by SHA-256.

A floating HIF branch may be useful during upstream development, but it is not
a toolchain input. Adopting a newer HIF baseline means updating the coordinated
tuple and requalifying it before the toolchain pin moves.

## HARM baseline

HARM is pinned by commit together with the exact CMake, ANTLR4, Spot, and Boost
inputs used to build it. The runtime image contains only the miner and its
required shared libraries; build trees remain isolated in the builder stage.

The toolchain qualifies the `Verilator -> VCD -> HARM -> SVA` path. HARM v3's
top-N candidate ordering/set is not byte-deterministic across identical runs,
including with `--max-threads 1`, so qualification checks successful mining and
SVA production rather than exact textual equality.

## Validation layers

Validation is intentionally split into two layers:

1. **Toolchain qualification** checks that the environment is internally
   healthy. `toolchain-doctor` exercises installed tools with small functional
   smoke tests.
2. **Course qualification** belongs to each consuming course repository. It
   verifies that the course's exercises and workflows work with a particular
   toolchain revision.

A green doctor therefore means "the environment works", not "every course has
been qualified against this revision".

## Runtime model

Docker and Apptainer are normalized through `bin/hdl-toolchain`:

- the selected workspace is mounted at `/work`;
- network access is disabled by default;
- generated files remain owned by the invoking user where supported;
- scratch/cache state lives under `.toolchain/` in the workspace;
- GUI applications are conveniences, not portability requirements.

Simulation artifacts such as VCD/FST files are portable outputs. A host-native
waveform viewer may be used instead of running a GUI inside the container.

## Repository boundary

Shared infrastructure belongs here: operating-system dependencies, simulators,
synthesis/verification tools, HIF, packaging, launchers, and generic health
checks.

Course repositories own pedagogical wrappers, exercises, expected outputs, and
course-specific acceptance tests. Consumers should eventually pin a released
image or digest rather than track this repository's `main` branch implicitly.
