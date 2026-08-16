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

# The container is run with the invoking user's uid so that generated files
# belong to the student, but that uid has no entry in the image's /etc/passwd.
# Without one, whoami fails and Python's getpass.getuser() raises KeyError.
# Add a synthetic entry when the root filesystem allows it. Under Apptainer
# this code does not run at all, and it does not need to: that installation
# has `config passwd = yes` and synthesises the host user's entry itself.
if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
    if [ -w /etc/passwd ]; then
        printf 'student:x:%s:%s:Course user:%s:/bin/bash\n' \
            "$(id -u)" "$(id -g)" "${HOME}" >> /etc/passwd
    fi
    [ -n "${USER:-}" ]    || { USER=student;    export USER; }
    [ -n "${LOGNAME:-}" ] || { LOGNAME=student; export LOGNAME; }
fi

exec "$@"
