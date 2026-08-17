# syntax=docker/dockerfile:1.7
# -----------------------------------------------------------------------------
# HDL course toolchain.
#
# This file is the canonical OCI build description. The Apptainer SIF is
# derived from this image rather than installing the toolchain independently;
# see apptainer/hdl-course-toolchain.def.
#
# Every build-time version is pinned in versions.yml and passed as a build ARG.
# ARGs deliberately have no defaults, and scripts/versions.py checks that the
# manifest and this file cannot silently drift apart.
#
# Ubuntu 22.04 is retained because the available OpenROAD binary package needs
# libpython3.10 and the pre-t64 Qt5 package names provided by jammy.
# -----------------------------------------------------------------------------
ARG BASE_IMAGE

# -----------------------------------------------------------------------------
# Stage: base -- packages shared by builders and runtime.
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

# Runtime status and provenance consumed by the toolchain doctor.
RUN mkdir -p /opt/toolchain/bin /opt/toolchain/status /opt/toolchain/report

# -----------------------------------------------------------------------------
# Stage: builder-eda -- simulation and synthesis tools built from source.
# -----------------------------------------------------------------------------
FROM base AS builder-eda
ARG IVERILOG_REF
ARG VERILATOR_REF
ARG YOSYS_REF
ARG IVERILOG_SHA256
ARG VERILATOR_SHA256
ARG YOSYS_SHA256

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential autoconf automake gperf flex bison \
        libfl-dev libreadline-dev zlib1g-dev libffi-dev \
        tcl-dev pkg-config help2man perl python3-dev \
 && rm -rf /var/lib/apt/lists/*
# libfl-dev, not flex, ships FlexLexer.h on Ubuntu; Verilator needs it.

COPY container/fetch.sh /usr/local/bin/fetch.sh
RUN chmod 0755 /usr/local/bin/fetch.sh

# Source archives are fetched and SHA-256 verified on the host, then verified
# again while unpacking in the build. Each stage copies only what it consumes so
# unrelated source changes do not invalidate its cache.
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

# Verilator. Its version comes from configure.ac rather than git metadata, so a
# source archive still reports the intended version.
RUN fetch.sh --local "${VERILATOR_SHA256}" /src/archives/verilator.tar.gz \
        /src/verilator --strip-components=1 \
 && cd /src/verilator \
 && autoconf \
 && ./configure --prefix=/usr/local \
 && make -j"$(nproc)" \
 && make DESTDIR=/dest install

# Yosys uses the release archive that vendors ABC. The archive is flat and must
# not have a leading path component stripped.
RUN fetch.sh --local "${YOSYS_SHA256}" /src/archives/yosys.tar.gz /src/yosys \
 && cd /src/yosys \
 && make -j"$(nproc)" PREFIX=/usr/local \
 && make install PREFIX=/usr/local DESTDIR=/dest

# -----------------------------------------------------------------------------
# Stage: builder-hif -- coordinated HIF baseline from pinned source archives.
#
# Two upstream details are handled without patching the projects:
#
#  1. The HIF CMake projects hard-code /usr/local as CMAKE_INSTALL_PREFIX;
#     `cmake --install --prefix` redirects installation to /opt/hif.
#  2. hif-muffin declares Galfurian/json with GIT_TAG main. A pinned copy is
#     supplied through FETCHCONTENT_SOURCE_DIR_JSON.
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
COPY .out/sources/hif-core.tar.gz .out/sources/hif-frontend.tar.gz \
     .out/sources/hif-backend.tar.gz .out/sources/hif-muffin.tar.gz \
     .out/sources/hif-json.tar.gz /src/archives/
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

# The remaining projects find hif-core through their cmake/FindHIF.cmake,
# which searches HIF_DIR first.
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

# Record the authoritative source tuple inside the image. The binaries' own
# version strings are not sufficient to identify this baseline.
RUN { \
      echo "hif-core     ${HIF_CORE_REF}"; \
      echo "hif-frontend ${HIF_FRONTEND_REF}"; \
      echo "hif-backend  ${HIF_BACKEND_REF}"; \
      echo "hif-muffin   ${HIF_MUFFIN_REF}"; \
      echo "json         ${HIF_JSON_REF}"; \
    } > /opt/hif/BUILD_PINS.txt

# -----------------------------------------------------------------------------
# Stage: builder-rust -- Quaigh, an optional ATPG/logic-optimisation tool.
# -----------------------------------------------------------------------------
FROM base AS builder-rust
ARG RUST_VERSION
ARG QUAIGH_VERSION

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

RUN /opt/cargo/bin/cargo install quaigh --version "${QUAIGH_VERSION}" \
        --locked --root /dest/usr/local \
 && rm -f /dest/usr/local/.crates.toml /dest/usr/local/.crates2.json

# -----------------------------------------------------------------------------
# Stage: builder-fault -- optional Fault ATPG/fault-simulation tool.
#
# Fault is built from source against an official Swift toolchain. Its outcome
# is recorded rather than aborting the image build, because it is an optional
# capability and the doctor reports its status explicitly.
# -----------------------------------------------------------------------------
FROM base AS builder-fault
ARG SWIFT_VERSION
ARG SWIFT_SHA256
ARG FAULT_REF
ARG FAULT_SHA256

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
# A C++ compiler remains intentionally: Verilator and cocotb compile designs at
# run time, so build-essential is a real runtime dependency.
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

# Poco is a runtime dependency of libhif. The ld.so.conf.d entry makes libhif
# resolvable without requiring callers to set LD_LIBRARY_PATH.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libpocofoundation80 libpocoutil80 libpocoxml80 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder-hif /opt/hif/ /opt/hif/
RUN echo /opt/hif/lib > /etc/ld.so.conf.d/hif.conf && ldconfig

# Python dependencies are installed from the resolved lock file.
COPY requirements.txt /opt/toolchain/requirements.txt
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/venv/bin/pip install --no-cache-dir -r /opt/toolchain/requirements.txt

ENV VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:/opt/toolchain/bin:/opt/hif/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

# Optional/candidate tools.
COPY --from=builder-rust /dest/ /
COPY --from=builder-fault /dest/opt/ /opt/
RUN if [ -x /opt/fault/bin/fault ]; then \
        echo /opt/fault/lib > /etc/ld.so.conf.d/fault.conf; \
        ln -sf /opt/fault/bin/fault /usr/local/bin/fault; \
        ldconfig; \
    fi
ENV PYTHON_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.10.so.1.0

# OpenROAD is available only for amd64 in the selected binary channel. Other
# architectures record the capability as unsupported rather than failing the
# whole image build.
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

# Tools whose installation would already have aborted the build are recorded as
# healthy here for the same status interface used by optional components.
RUN for tool in iverilog vvp verilator yosys ngspice quaigh muffin \
                verilog2hif hif2verilog cocotb pytest graphviz gtkwave; do \
        echo ok > "/opt/toolchain/status/${tool}.status"; \
    done

COPY --from=builder-shell /opt/oh-my-zsh/ /opt/oh-my-zsh/

COPY container/profile.sh /etc/profile.d/hdl-course-toolchain.sh
RUN mkdir -p /opt/toolchain/zsh
COPY container/zshrc /opt/toolchain/zsh/.zshrc
COPY container/entrypoint.sh /opt/toolchain/bin/entrypoint.sh

# The doctor turns presence checks into small functional tests for the
# components the environment depends on.
COPY doctor/ /opt/toolchain/doctor/
RUN printf '#!/bin/sh\nexec /opt/venv/bin/python3 /opt/toolchain/doctor/toolchain_doctor.py "$@"\n' \
      > /opt/toolchain/bin/toolchain-doctor \
 && chmod 0755 /opt/toolchain/bin/entrypoint.sh /opt/toolchain/bin/toolchain-doctor \
                /etc/profile.d/hdl-course-toolchain.sh \
 && ldconfig

# Record the exact archive package versions resolved into this image. Generic
# base packages are not yet pinned to an Ubuntu snapshot; see versions.yml.
RUN dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' \
      | sort > /opt/toolchain/report/apt-packages.txt

WORKDIR /work
ENTRYPOINT ["/opt/toolchain/bin/entrypoint.sh"]
CMD ["bash", "-l"]
