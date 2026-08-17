SHELL := /bin/bash
.DEFAULT_GOAL := help

PYTHON ?= python3
WORKSPACE ?= $(CURDIR)

.PHONY: help software check fetch build doctor shell export sif clean

help: ## Show the available commands
	@printf 'HDL Course Toolchain\n\n'
	@printf 'Inspect\n'
	@printf '  make software  Show planned software, versions, sources, and architecture\n'
	@printf '  make check     Run fast repository consistency checks\n'
	@printf '\nBuild\n'
	@printf '  make fetch     Download and verify pinned source archives\n'
	@printf '  make build     Fetch sources and build the OCI image\n'
	@printf '\nRun\n'
	@printf '  make doctor    Run functional smoke tests inside the OCI image\n'
	@printf '  make shell     Open an interactive shell inside the OCI image\n'
	@printf '\nArtifacts\n'
	@printf '  make export    Export the OCI image as a docker-archive\n'
	@printf '  make sif       Build the Apptainer SIF from the OCI image\n'
	@printf '\nMaintenance\n'
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
	@for file in bin/hdl-toolchain container/*.sh scripts/*.sh; do bash -n "$$file"; done
	@printf '    OK  shell scripts parse cleanly\n'
	@printf '\nRepository checks passed.\n'

fetch: ## Download and verify source archives
	@./scripts/fetch-sources.sh

build: fetch ## Build the OCI image
	@./scripts/build-image.sh

doctor: ## Run the toolchain doctor in Docker
	@./bin/hdl-toolchain --workspace "$(WORKSPACE)" -- toolchain-doctor

shell: ## Open an interactive shell in Docker
	@./bin/hdl-toolchain --workspace "$(WORKSPACE)" -- zsh -l

export: ## Export the OCI image for Apptainer
	@./scripts/export-oci.sh

sif: build ## Derive the Apptainer SIF from the OCI image
	@./scripts/build-sif.sh

clean: ## Remove generated artifacts
	@rm -rf .out
