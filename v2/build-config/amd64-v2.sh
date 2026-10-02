#! /bin/bash
# PikaOS x86-64-v2 build configuration.
#
# Ported verbatim from PikaOS's own official v2 pbuilder config
# (repo-tools/run-upstream-build -> pika-pbuilder/var/cache/pbuilder/rc.examples/pbuilderrc-v2)
# with PIKA_BUILD_ARCH/GOAMD64 added so package main.sh scripts can echo the
# arch marker. This is the authoritative v2 flag set; do not hand-tune.
export PIKA_BUILD_ARCH="amd64-v2"
export DEBIAN_FRONTEND="noninteractive"
export DEB_BUILD_MAINT_OPTIONS="-march=x86-64-v2 -O3 -w -DQT_NO_VERSION_TAGGING"
export DEB_CFLAGS_MAINT_APPEND="-march=x86-64-v2 -O3 -w -DQT_NO_VERSION_TAGGING"
export DEB_CPPFLAGS_MAINT_APPEND="-march=x86-64-v2 -O3 -w -DQT_NO_VERSION_TAGGING"
export DEB_CXXFLAGS_MAINT_APPEND="-march=x86-64-v2 -O3 -w -DQT_NO_VERSION_TAGGING"
export DEB_LDFLAGS_MAINT_APPEND="-O3"
export DEB_BUILD_OPTIONS="parallel=$(nproc) nocheck notest terse"
export DPKG_GENSYMBOLS_CHECK_LEVEL=0
export GOAMD64="v2"
