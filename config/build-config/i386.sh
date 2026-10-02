#! /bin/bash
# 32-bit side packages (Steam/Proton wine). No -march: i386 stays baseline so
# the 32-bit libs run on anything, matching upstream pika-build-config/i386.sh.
export PIKA_BUILD_ARCH="i386"
export DEBIAN_FRONTEND="noninteractive"
export DEB_BUILD_OPTIONS="nocheck notest terse"
export DPKG_GENSYMBOLS_CHECK_LEVEL=0