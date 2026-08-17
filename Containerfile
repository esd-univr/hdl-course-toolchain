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
#
# Each stage copies only the archives it needs. Copying the whole directory
# made adding a source for one tool invalidate every other tool's layer.
COPY .out/sources/iverilog.tar.gz .out/sources/verilator.tar.gz \
     .out/sources/yosys.tar.gz /src/archives/

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
ARG HIF_MUFFIN_ARCHIVE
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
COPY .out/sources/hif-core.tar.gz .out/sources/hif-frontend.tar.gz \
     .out/sources/hif-muffin-develop.tar.gz \
     .out/sources/hif-backend.tar.gz .out/sources/hif-muffin.tar.gz \
     .out/sources/hif-json.tar.gz /src/archives/
RUN chmod 0755 /usr/local/bin/fetch.sh \
 && fetch.sh --local "${HIF_CORE_SHA256}"     /src/archives/hif-core.tar.gz     /src/hif-core     --strip-components=1 \
 && fetch.sh --local "${HIF_FRONTEND_SHA256}" /src/archives/hif-frontend.tar.gz /src/hif-frontend --strip-components=1 \
 && fetch.sh --local "${HIF_BACKEND_SHA256}"  /src/archives/hif-backend.tar.gz  /src/hif-backend  --strip-components=1 \
 && fetch.sh --local "${HIF_MUFFIN_SHA256}"   "/src/archives/${HIF_MUFFIN_ARCHIVE}"   /src/hif-muffin   --strip-components=1 \
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
# Stage: builder-rust -- Quaigh, an ATPG and logic-optimisation candidate.
#
# The Rust toolchain is build-time only and does not reach the runtime image.
# The retry settings are not decoration: this host's container egress is
# intermittently flaky, and a single dropped connection would otherwise cost
# the whole build.
# -----------------------------------------------------------------------------
FROM base AS builder-rust
ARG RUST_VERSION
ARG QUAIGH_VERSION

# Quaigh's dependency graph reaches openssl-sys, libgit2-sys and libssh2-sys,
# all of which need system headers and pkg-config to build.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential pkg-config libssl-dev zlib1g-dev cmake \
 && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    CARGO_NET_RETRY=10 \
    CARGO_HTTP_MULTIPLEXING=false \
    CARGO_HTTP_LOW_SPEED_LIMIT=1000 \
    CARGO_HTTP_TIMEOUT=120

RUN set -eu; \
    attempt=1; \
    until curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
              --connect-timeout 30 https://sh.rustup.rs -o /tmp/rustup.sh; do \
        [ "${attempt}" -lt 3 ] || { echo "could not download rustup" >&2; exit 1; }; \
        attempt=$((attempt + 1)); sleep 10; \
    done; \
    sh /tmp/rustup.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_VERSION}"; \
    rm -f /tmp/rustup.sh

# --locked so the crate's own Cargo.lock decides the dependency graph rather
# than a fresh resolution, which would not be reproducible.
RUN /opt/cargo/bin/cargo install quaigh --version "${QUAIGH_VERSION}" \
        --locked --root /dest/usr/local \
 && rm -f /dest/usr/local/.crates.toml /dest/usr/local/.crates2.json

# -----------------------------------------------------------------------------
# Stage: builder-fault -- Fault, an ATPG / fault-simulation candidate.
#
# Fault is written in Swift and upstream's supported install path is Nix, which
# is out of scope here, so it is built from source against an official Swift
# toolchain. The toolchain is build-time only; only the binary and the Swift
# runtime libraries reach the runtime image.
#
# The outcome is recorded rather than allowed to abort the build: this is a
# candidate, and a kitchen sink that fails entirely because one experimental
# tool broke would tell us less than one that reports which tool broke.
# -----------------------------------------------------------------------------
FROM base AS builder-fault
ARG SWIFT_VERSION
ARG SWIFT_SHA256
ARG FAULT_REF
ARG FAULT_SHA256

# Swift needs a C toolchain to link; without gcc it fails while compiling the
# package manifest itself, with an error that looks nothing like the cause.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential binutils libc6-dev libcurl4-openssl-dev libedit2 \
        libpython3.10 libsqlite3-0 libxml2-dev libz3-4 pkg-config tzdata \
        unzip zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

COPY container/fetch.sh /usr/local/bin/fetch.sh
COPY .out/sources/swift.tar.gz .out/sources/fault.tar.gz /src/archives/
RUN chmod 0755 /usr/local/bin/fetch.sh

RUN set -eu; \
    status=/dest/opt/toolchain/status/fault.status; \
    log=/dest/opt/toolchain/report/fault.log; \
    mkdir -p /dest/opt/toolchain/status /dest/opt/toolchain/report /dest/opt/fault/bin; \
    { \
      echo "=== Fault ${FAULT_REF} against Swift ${SWIFT_VERSION} ==="; \
      fetch.sh --local "${SWIFT_SHA256}" /src/archives/swift.tar.gz /opt/swift --strip-components=2; \
      fetch.sh --local "${FAULT_SHA256}" /src/archives/fault.tar.gz /src/fault --strip-components=1; \
      export PATH=/opt/swift/bin:${PATH}; \
      swift --version; \
      cd /src/fault; \
      swift build -c release; \
      cp "$(swift build -c release --show-bin-path)/fault" /dest/opt/fault/bin/fault; \
      mkdir -p /dest/opt/fault/lib; \
      cp -a /opt/swift/lib/swift/linux/. /dest/opt/fault/lib/; \
    } > "${log}" 2>&1 && echo ok > "${status}" || echo failed > "${status}"; \
    echo "fault: $(cat "${status}")"; \
    tail -5 "${log}"

# -----------------------------------------------------------------------------
# Stage: builder-shell -- frozen interactive shell assets.
#
# Oh My Zsh and zsh-syntax-highlighting are unpacked from source archives
# fetched and SHA-256 verified by the same mechanism used for the other pinned
# sources. No git metadata or build-time network access reaches the runtime.
# -----------------------------------------------------------------------------
FROM base AS builder-shell
ARG OH_MY_ZSH_REF
ARG OH_MY_ZSH_SHA256
ARG ZSH_SYNTAX_HIGHLIGHTING_REF
ARG ZSH_SYNTAX_HIGHLIGHTING_SHA256

COPY container/fetch.sh /usr/local/bin/fetch.sh
COPY .out/sources/oh-my-zsh.tar.gz \
     .out/sources/zsh-syntax-highlighting.tar.gz /src/archives/

RUN chmod 0755 /usr/local/bin/fetch.sh \
 && fetch.sh --local "${OH_MY_ZSH_SHA256}" \
        /src/archives/oh-my-zsh.tar.gz \
        /opt/oh-my-zsh --strip-components=1 \
 && fetch.sh --local "${ZSH_SYNTAX_HIGHLIGHTING_SHA256}" \
        /src/archives/zsh-syntax-highlighting.tar.gz \
        /opt/oh-my-zsh/custom/plugins/zsh-syntax-highlighting \
        --strip-components=1 \
 && chmod -R go-w /opt/oh-my-zsh \
 && printf 'oh-my-zsh %s\nzsh-syntax-highlighting %s\n' \
        "${OH_MY_ZSH_REF}" "${ZSH_SYNTAX_HIGHLIGHTING_REF}" \
        > /opt/oh-my-zsh/BUILD_PINS.txt


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
        build-essential libnss-wrapper zsh z3 \
        libreadline8 zlib1g libffi8 tcl8.6 libgomp1 perl python3-dev \
        libpython3.10 libcurl4 libedit2 libsqlite3-0 libxml2 libz3-4 \
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

# Quaigh (candidate).
COPY --from=builder-rust /dest/ /

# Fault (candidate). May be a recorded failure; the doctor reads the status.
# PythonKit dlopens libpython at run time and cannot find it unaided, and Fault
# drives pyverilog and nl2bench through that interpreter -- both are in the
# toolchain venv, see requirements.in.
COPY --from=builder-fault /dest/opt/ /opt/
RUN if [ -x /opt/fault/bin/fault ]; then \
        echo /opt/fault/lib > /etc/ld.so.conf.d/fault.conf; \
        ln -sf /opt/fault/bin/fault /usr/local/bin/fault; \
        ldconfig; \
    fi
ENV PYTHON_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.10.so.1.0

# OpenROAD (candidate), from the only official binary channel. amd64 only: no
# arm64 asset has ever been published, so on another architecture this records
# "unsupported-arch" and the doctor reports it rather than the tool silently
# being absent.
ARG OPENROAD_DEB_RELEASE
ARG OPENROAD_DEB_SHA256
COPY .out/sources/openroad.deb /src/archives/openroad.deb
RUN set -eu; \
    status=/opt/toolchain/status/openroad.status; \
    log=/opt/toolchain/report/openroad.log; \
    architecture="$(dpkg --print-architecture)"; \
    if [ "${architecture}" != "amd64" ]; then \
        echo "unsupported-arch" > "${status}"; \
        printf 'No OpenROAD binary is published for %s; every release asset is amd64.\n' \
            "${architecture}" > "${log}"; \
        rm -f /src/archives/openroad.deb; \
    else \
        { \
          actual="$(sha256sum /src/archives/openroad.deb | cut -d' ' -f1)"; \
          [ "${actual}" = "${OPENROAD_DEB_SHA256}" ] \
            || { echo "SHA-256 mismatch: ${actual}"; exit 1; }; \
          echo "openroad release ${OPENROAD_DEB_RELEASE} sha256 ${actual}"; \
          apt-get update; \
          apt-get install -y --no-install-recommends /src/archives/openroad.deb; \
          rm -rf /var/lib/apt/lists/* /src/archives/openroad.deb; \
        } > "${log}" 2>&1 && echo ok > "${status}" || echo failed > "${status}"; \
    fi; \
    echo "openroad: $(cat "${status}")"

# Every candidate reports a status so a partially successful kitchen sink is
# visible rather than green. The tools whose failure would have aborted the
# build are recorded as ok here for uniformity.
RUN for tool in iverilog vvp verilator yosys ngspice quaigh muffin \
                verilog2hif hif2verilog cocotb pytest graphviz gtkwave; do \
        echo ok > "/opt/toolchain/status/${tool}.status"; \
    done

# Frozen interactive shell environment.
COPY --from=builder-shell /opt/oh-my-zsh/ /opt/oh-my-zsh/

COPY container/profile.sh /etc/profile.d/stc-toolchain.sh
RUN mkdir -p /opt/toolchain/zsh
COPY container/zshrc /opt/toolchain/zsh/.zshrc
COPY container/entrypoint.sh /opt/toolchain/bin/entrypoint.sh

# The toolchain self-test. It runs inside the image, needs no network, and is
# what turns "the tool is on PATH" into "the tool did a job and the answer was
# right" for the components the course would stand on.
COPY doctor/ /opt/toolchain/doctor/
RUN printf '#!/bin/sh\nexec /opt/venv/bin/python3 /opt/toolchain/doctor/toolchain_doctor.py "$@"\n' \
      > /opt/toolchain/bin/toolchain-doctor \
 && chmod 0755 /opt/toolchain/bin/entrypoint.sh /opt/toolchain/bin/toolchain-doctor \
                /etc/profile.d/stc-toolchain.sh \
 && ldconfig

# Record exactly which archive packages this image resolved to. The generic
# base packages are not version-pinned (see versions.yml), so this manifest is
# what makes a given image describable after the fact.
RUN dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' \
      | sort > /opt/toolchain/report/apt-packages.txt

WORKDIR /work
ENTRYPOINT ["/opt/toolchain/bin/entrypoint.sh"]
CMD ["bash", "-l"]
