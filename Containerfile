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
# Stage: builder-hif -- HIF v1.1.0 from the published sources.
#
# Albion's development checkouts are deliberately NOT used: the point of this
# image is to prove the environment is reproducible from released sources, so
# the four projects are rebuilt here from pinned, digest-verified archives.
#
# Two upstream facts are handled here without patching anything:
#
#  1. Every CMakeLists.txt hard-codes set(CMAKE_INSTALL_PREFIX /usr/local)
#     unconditionally, which overrides -DCMAKE_INSTALL_PREFIX. CMake's
#     `--install --prefix` overrides it back at install time.
#  2. hif-muffin FetchContents Galfurian/json at GIT_TAG main -- unpinned. The
#     pinned source is pre-placed and injected via FETCHCONTENT_SOURCE_DIR_JSON.
# -----------------------------------------------------------------------------
FROM base AS builder-hif
ARG HIF_CORE_REF
ARG HIF_FRONTEND_REF
ARG HIF_BACKEND_REF
ARG HIF_MUFFIN_REF
ARG HIF_JSON_REF
ARG HIF_CORE_SHA256
ARG HIF_FRONTEND_SHA256
ARG HIF_BACKEND_SHA256
ARG HIF_MUFFIN_SHA256
ARG HIF_JSON_SHA256

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential cmake flex bison libpoco-dev \
 && rm -rf /var/lib/apt/lists/*

COPY container/fetch.sh /usr/local/bin/fetch.sh
COPY .out/sources/ /src/archives/
RUN chmod 0755 /usr/local/bin/fetch.sh \
 && fetch.sh --local "${HIF_CORE_SHA256}"     /src/archives/hif-core.tar.gz     /src/hif-core     --strip-components=1 \
 && fetch.sh --local "${HIF_FRONTEND_SHA256}" /src/archives/hif-frontend.tar.gz /src/hif-frontend --strip-components=1 \
 && fetch.sh --local "${HIF_BACKEND_SHA256}"  /src/archives/hif-backend.tar.gz  /src/hif-backend  --strip-components=1 \
 && fetch.sh --local "${HIF_MUFFIN_SHA256}"   /src/archives/hif-muffin.tar.gz   /src/hif-muffin   --strip-components=1 \
 && fetch.sh --local "${HIF_JSON_SHA256}"     /src/archives/hif-json.tar.gz     /src/json         --strip-components=1

# hif-core first: the other three link against it.
RUN cmake -S /src/hif-core -B /src/hif-core/build \
        -DCMAKE_BUILD_TYPE=Release -DSTRICT_WARNINGS=OFF \
 && cmake --build /src/hif-core/build -j"$(nproc)" \
 && cmake --install /src/hif-core/build --prefix /opt/hif

# The other three find hif-core through their cmake/FindHIF.cmake, which
# searches ${HIF_DIR} first.
RUN set -eu; \
    for name in hif-frontend hif-backend hif-muffin; do \
        echo "=== building ${name} ==="; \
        cmake -S "/src/${name}" -B "/src/${name}/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DSTRICT_WARNINGS=OFF \
            -DHIF_DIR=/opt/hif \
            -DFETCHCONTENT_SOURCE_DIR_JSON=/src/json; \
        cmake --build "/src/${name}/build" -j"$(nproc)"; \
        cmake --install "/src/${name}/build" --prefix /opt/hif; \
    done

# Record exactly what was built. The binaries all report "version 1.0.0" even
# at tag v1.1.0, so these commit pins are the only reliable identity.
RUN { \
      echo "hif-core     ${HIF_CORE_REF}"; \
      echo "hif-frontend ${HIF_FRONTEND_REF}"; \
      echo "hif-backend  ${HIF_BACKEND_REF}"; \
      echo "hif-muffin   ${HIF_MUFFIN_REF}"; \
      echo "json         ${HIF_JSON_REF}"; \
    } > /opt/hif/BUILD_PINS.txt

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

# HIF. Poco is a runtime dependency of libhif; the ld.so.conf.d entry is what
# makes the shared library resolvable without any caller setting
# LD_LIBRARY_PATH, which is one of the things this spike has to prove.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libpocofoundation80 libpocoutil80 libpocoxml80 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder-hif /opt/hif/ /opt/hif/
RUN echo /opt/hif/lib > /etc/ld.so.conf.d/hif.conf && ldconfig

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
