#!/bin/sh
# Normalise the environment, then exec whatever was asked for.
#
# This runs for `docker run`. It deliberately does NOT run for
# `apptainer exec`, which ignores the OCI entrypoint -- so anything that must
# hold under both engines lives in profile.sh (sourced below and by the SIF's
# %environment block) or is set by toolchain/bin/stc-container, which is the
# supported way to launch either engine.
set -eu

# The single canonical environment definition.
. /etc/profile.d/stc-toolchain.sh

# The image is immutable and contains no course material. Everything a lab
# writes must land in the bind-mounted workspace, so HOME points there unless
# the caller already chose one that exists.
if [ ! -d "${HOME:-/nonexistent}" ]; then
    HOME=/work
    export HOME
fi

# The container runs with the invoking user's numeric uid/gid so generated
# files remain owned by the student on the host.  Those ids normally have no
# names inside the immutable image.  nss_wrapper provides a synthetic
# `student` identity without modifying /etc/passwd or /etc/group.
if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
    nss_dir="${TMPDIR:-/tmp}/nss"
    mkdir -p "${nss_dir}"
    cp /etc/passwd "${nss_dir}/passwd"
    cp /etc/group "${nss_dir}/group"

    printf 'student:x:%s:%s:Course student:%s:/bin/bash\n' \
        "$(id -u)" "$(id -g)" "${HOME}" >> "${nss_dir}/passwd"

    if ! getent group "$(id -g)" >/dev/null 2>&1; then
        printf 'student:x:%s:\n' "$(id -g)" >> "${nss_dir}/group"
    fi

    NSS_WRAPPER_PASSWD="${nss_dir}/passwd"
    NSS_WRAPPER_GROUP="${nss_dir}/group"
    LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libnss_wrapper.so${LD_PRELOAD:+:${LD_PRELOAD}}"
    USER=student
    LOGNAME=student
    export NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP LD_PRELOAD USER LOGNAME
fi

exec "$@"
