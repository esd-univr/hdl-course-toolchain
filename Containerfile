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

# -----------------------------------------------------------------------------
# Stage: builder-eda -- source builds of the simulation and synthesis tools.
#
# Ubuntu 22.04 packages Icarus 11.0, Verilator 4.038 and Yosys 0.9, all too old
# for this course. Each is therefore built from a pinned tag into a DESTDIR, so
# the runtime can take the installed tree without inheriting the sources or the
# build dependencies.
# -----------------------------------------------------------------------------
FROM base AS builder-eda
ARG IVERILOG_REF
ARG VERILATOR_REF
ARG YOSYS_REF

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential autoconf automake gperf flex bison \
        libfl-dev libreadline-dev zlib1g-dev libffi-dev \
        tcl-dev pkg-config help2man perl python3-dev \
 && rm -rf /var/lib/apt/lists/*
# libfl-dev, not flex, is what ships FlexLexer.h on Ubuntu; Verilator needs it.

ARG IVERILOG_SHA256
ARG VERILATOR_SHA256
ARG YOSYS_SHA256

COPY container/fetch.sh /usr/local/bin/fetch.sh
RUN chmod 0755 /usr/local/bin/fetch.sh

# Source archives rather than git clones, fetched on the host by
# scripts/fetch-sources.sh and copied in. Cloning or downloading these from
# inside the build stalled repeatedly on this host while the identical download
# from the host took seconds. The archives carry their SHA-256 in versions.yml
# and are verified BOTH by the host fetcher and again here, so a corrupted or
# substituted archive fails the build rather than producing a mystery binary.
COPY .out/sources/ /src/archives/

# Icarus Verilog.
RUN fetch.sh --local "${IVERILOG_SHA256}" /src/archives/iverilog.tar.gz \
        /src/iverilog --strip-components=1 \
 && cd /src/iverilog \
 && sh autoconf.sh \
 && ./configure --prefix=/usr/local \
 && make -j"$(nproc)" \
 && make DESTDIR=/dest install

# Verilator. Its version string comes from configure.ac, not `git describe`, so
# building from an archive still reports the correct version.
RUN fetch.sh --local "${VERILATOR_SHA256}" /src/archives/verilator.tar.gz \
        /src/verilator --strip-components=1 \
 && cd /src/verilator \
 && autoconf \
 && ./configure --prefix=/usr/local \
 && make -j"$(nproc)" \
 && make DESTDIR=/dest install

# Yosys, from the release asset that vendors abc, so the build needs no second
# unpinned fetch. Note this archive is FLAT -- its members sit at the archive
# root -- so it must not be stripped.
RUN fetch.sh --local "${YOSYS_SHA256}" /src/archives/yosys.tar.gz /src/yosys \
 && cd /src/yosys \
 && make -j"$(nproc)" PREFIX=/usr/local \
 && make install PREFIX=/usr/local DESTDIR=/dest

# -----------------------------------------------------------------------------
# Stage: runtime -- the image that is actually run.
#
# It keeps a C++ compiler on purpose. Verilator and cocotb compile the design
# under test at run time, so build-essential here is a genuine runtime
# dependency and not leftover build scaffolding.
# -----------------------------------------------------------------------------
FROM base AS runtime
ARG NGSPICE_APT_VERSION
ARG GRAPHVIZ_APT_VERSION
ARG GTKWAVE_APT_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        libreadline8 zlib1g libffi8 tcl8.6 libgomp1 perl python3-dev \
        "ngspice=${NGSPICE_APT_VERSION}" \
        "graphviz=${GRAPHVIZ_APT_VERSION}" \
        "gtkwave=${GTKWAVE_APT_VERSION}" \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder-eda /dest/ /

# The Python environment. requirements.txt is a generated full lock, so no
# dependency resolution happens here and nothing is fetched at run time.
COPY requirements.txt /opt/toolchain/requirements.txt
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/venv/bin/pip install --no-cache-dir -r /opt/toolchain/requirements.txt

ENV VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:/opt/toolchain/bin:/opt/hif/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

COPY container/profile.sh /etc/profile.d/stc-toolchain.sh
COPY container/entrypoint.sh /opt/toolchain/bin/entrypoint.sh
RUN chmod 0755 /opt/toolchain/bin/entrypoint.sh /etc/profile.d/stc-toolchain.sh \
 && ldconfig

# Record exactly which archive packages this image resolved to. The generic
# base packages are not version-pinned (see versions.yml), so this manifest is
# what makes a given image describable after the fact.
RUN dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' \
      | sort > /opt/toolchain/report/apt-packages.txt

WORKDIR /work
ENTRYPOINT ["/opt/toolchain/bin/entrypoint.sh"]
CMD ["bash", "-l"]
