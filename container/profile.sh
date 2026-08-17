# HDL course toolchain environment.
#
# This is the ONE canonical definition of the toolchain environment. It is
# installed as /etc/profile.d/hdl-course-toolchain.sh and everything else sources it:
# the OCI entrypoint, the Apptainer %environment block, and login shells. Do
# not restate PATH anywhere else -- an earlier revision of this spike stated it
# in four places and they had already drifted apart.
#
# PATH is set absolutely rather than prepended, so the environment is identical
# no matter what the caller inherited. That is the whole point: the image is
# supposed to be the toolchain.
VIRTUAL_ENV=/opt/venv
ZDOTDIR=/opt/toolchain/zsh
PATH=/opt/venv/bin:/opt/toolchain/bin:/opt/hif/bin:/opt/harm/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
export VIRTUAL_ENV ZDOTDIR PATH
