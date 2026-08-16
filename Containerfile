# syntax=docker/dockerfile:1.7
# -----------------------------------------------------------------------------
# Systems Testing and Certification -- candidate course toolchain.
#
# This file is the canonical build description for the course environment. An
# Apptainer SIF is derived from the image it produces rather than installing
# anything a second time; see toolchain/apptainer/stc-toolchain.def.
#
# Every version this file consumes is pinned in toolchain/versions.yml and
# passed in as a build argument. The ARGs deliberately have no defaults, so a
# missing pin fails the build instead of silently resolving to "latest".
# toolchain/scripts/versions.py refuses to let the two files drift apart.
#
# Ubuntu 22.04 rather than 24.04: the only official OpenROAD binary channel
# publishes an ubuntu-22.04 .deb that needs libpython3.10 and the pre-t64
# libqt5* package names, neither of which exists on 24.04.
# -----------------------------------------------------------------------------
ARG BASE_IMAGE

# -----------------------------------------------------------------------------
# Stage: base -- the packages every later stage and the runtime share.
# -----------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS base

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=UTC

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash coreutils make git curl wget jq ca-certificates \
        python3 python3-venv python3-pip \
 && rm -rf /var/lib/apt/lists/*

# Where the build records what actually happened, so that a partially
# successful kitchen sink reports itself honestly at run time instead of
# looking green. Read by the toolchain doctor.
RUN mkdir -p /opt/toolchain/bin /opt/toolchain/status /opt/toolchain/report
