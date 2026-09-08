SHELL := /bin/bash
.DEFAULT_GOAL := help

PYTHON ?= python3
WORKSPACE ?= $(CURDIR)

# The image `make build` produces and `doctor` / `shell` qualify against. It
# defaults to the local name `hdl-course-toolchain:latest`, so a maintainer
# never needs the published GHCR image to qualify a candidate. The release
# workflow builds under the GHCR name by exporting HDL_TOOLCHAIN_IMAGE /
# HDL_TOOLCHAIN_TAG, which these variables pick up so `doctor` inspects the
# same image `build` made. `build` / `export` / `sif` read those env vars
# directly (scripts/build-image.sh), so they are not re-exported here.
IMAGE ?= $(or $(HDL_TOOLCHAIN_IMAGE),hdl-course-toolchain)
TAG   ?= $(or $(HDL_TOOLCHAIN_TAG),latest)
SIF   ?= $(or $(HDL_TOOLCHAIN_SIF),$(CURDIR)/.out/hdl-course-toolchain.sif)

.PHONY: help software check test updates bump fetch build doctor doctor-sif shell export sif qualify release clean

help: ## Show the available commands
	@printf 'HDL Course Toolchain\n\n'
	@printf 'Inspect\n'
	@printf '  make software  Show planned software, versions, sources, and architecture\n'
	@printf '  make check     Run fast repository consistency checks\n'
	@printf '  make test      Launcher and installer test suites\n'
	@printf '  make updates   Compare pinned versions against upstream (live network)\n'
	@printf '                 TOOL=<name> narrows it, REFRESH=1 re-probes advisories\n'
	@printf '\nBuild\n'
	@printf '  make fetch     Download and verify pinned source archives\n'
	@printf '  make build     Fetch sources and build the OCI image\n'
	@printf '\nRun\n'
	@printf '  make doctor     Run functional smoke tests inside the OCI image\n'
	@printf '  make doctor-sif Run the same smoke tests inside the Apptainer SIF\n'
	@printf '  make qualify    Full release qualification (build, both doctors, in order)\n'
	@printf '  make shell      Open an interactive shell inside the OCI image\n'
	@printf '\nArtifacts\n'
	@printf '  make export    Export the OCI image as a docker-archive\n'
	@printf '  make sif       Build the Apptainer SIF from the OCI image\n'
	@printf '\nMaintenance\n'
	@printf '  make bump      Bump one pin: make bump TOOL=yosys VERSION=v0.68\n'
	@printf '  make release   Cut a release: make release VERSION=vX.Y.Z (see docs/releasing.md)\n'
	@printf '  make clean     Remove generated artifacts under .out/\n'

software: ## Show the planned software inventory
	@$(PYTHON) scripts/versions.py --format software

check: ## Run fast repository checks
	@printf '==> unit tests\n'
	@$(PYTHON) -m unittest discover -s scripts
	@printf '    OK  unit tests passed\n'
	@printf '==> manifest\n'
	@$(PYTHON) scripts/versions.py --format check | sed 's/^/    /'
	@printf '==> shell syntax\n'
	@for file in bin/hdl-toolchain install.sh uninstall.sh container/*.sh scripts/*.sh; do bash -n "$$file"; done
	@printf '    OK  shell scripts parse cleanly\n'
	@printf '==> installer digest\n'
	@./scripts/sync-installer-digest.sh --check | sed 's/^/    /'
	@printf '\nRepository checks passed.\n'

test: ## Run the launcher, installer and uninstaller test suites
	@printf '==> launcher tests\n'
	@bash scripts/test_hdl_toolchain.sh
	@printf '\n==> installer tests\n'
	@bash scripts/test_install.sh
	@printf '\n==> uninstaller tests\n'
	@bash scripts/test_uninstall.sh

release: ## Cut a release (git half); CI builds and publishes. make release VERSION=vX.Y.Z
	@test -n "$(VERSION)" || { printf 'usage: make release VERSION=vX.Y.Z\n' >&2; exit 2; }
	@./scripts/release.sh "$(VERSION)"

updates: ## Report pinned versions against upstream (network)
	@$(PYTHON) scripts/configure.py check-updates $(if $(TOOL),--tool $(TOOL)) $(if $(REFRESH),--refresh)

bump: ## Bump one pin: make bump TOOL=yosys VERSION=v0.68
	@$(PYTHON) scripts/configure.py bump --tool "$(TOOL)" --version "$(VERSION)" $(if $(DRY_RUN),--dry-run)

fetch: ## Download and verify source archives
	@./scripts/fetch-sources.sh

build: fetch ## Build the OCI image
	@./scripts/build-image.sh

doctor: ## Run the toolchain doctor in Docker
	@./scripts/artifact-status.sh docker
	@./bin/hdl-toolchain --image $(IMAGE):$(TAG) --pull never --workspace "$(WORKSPACE)" -- toolchain-doctor

doctor-sif: ## Run the toolchain doctor in the Apptainer SIF
	@./scripts/artifact-status.sh apptainer
	@./bin/hdl-toolchain --engine apptainer --sif "$(SIF)" --workspace "$(WORKSPACE)" -- toolchain-doctor

shell: ## Open an interactive shell in Docker
	@./bin/hdl-toolchain --image $(IMAGE):$(TAG) --pull never --workspace "$(WORKSPACE)" -- zsh -l

export: ## Export the OCI image for Apptainer
	@./scripts/export-oci.sh

sif: build ## Derive the Apptainer SIF from the OCI image
	@./scripts/build-sif.sh

qualify: ## Run the full release qualification in order
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
	@printf '\n==> qualification summary\n'
	@printf '    repository checks     PASS\n'
	@printf '    OCI/Docker build      PASS\n'
	@printf '    Docker doctor         PASS\n'
	@printf '    Apptainer SIF build   PASS\n'
	@printf '    Apptainer doctor      PASS\n'
	@printf '    architecture          %s\n' "$$(uname -m)"
	@printf '    image                 %s\n' \
	    "$$(docker image inspect $(IMAGE):$(TAG) --format '{{.Id}}' | cut -c8-19)"
	@printf '    build inputs          %s\n' "$$(cat .out/build-inputs.docker.sha256 | cut -c1-12)"
	@printf '    source commit         %s\n' "$$(git rev-parse HEAD)"
	@printf '\nQualification passed. This block is the evidence for a release.\n'

clean: ## Remove generated artifacts
	@rm -rf .out
