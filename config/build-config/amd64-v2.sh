#! /bin/bash
# PikaOS-v2 build config :: the x86-64-v2 counterpart of upstream
# pika-build-config/amd64-v3.sh
#
# Upstream PikaOS targets -march=x86-64-v3 (-O3 -flto -mavx2). Everything below
# is identical in shape but pinned to x86-64-v2, which is the ceiling for
# Sandy/Ivy Bridge (e.g. Core i5-3550: AVX yes, AVX2/FMA/BMI no).
#
#   source config/build-config/amd64-v2.sh
export PIKA_BUILD_ARCH="amd64-v2"
export DEBIAN_FRONTEND="noninteractive"

_V2="-march=x86-64-v2 -mtune=generic -O3 -flto -fuse-linker-plugin -falign-functions=32"

export DEB_BUILD_MAINT_OPTIONS="optimize=+lto ${_V2}"
export DEB_CFLAGS_MAINT_APPEND="${_V2}"
export DEB_CPPFLAGS_MAINT_APPEND="${_V2}"
export DEB_CXXFLAGS_MAINT_APPEND="${_V2}"
export DEB_LDFLAGS_MAINT_APPEND="-march=x86-64-v2 -flto -fuse-linker-plugin"

export DEB_BUILD_OPTIONS="nocheck notest terse"
export DPKG_GENSYMBOLS_CHECK_LEVEL=0

# Go has no -march; it uses GOAMD64 levels. v2 == NEHALEM/SANDYBRIDGE/IVYBRIDGE.
export GOAMD64="v2"

# Rust: target-cpu for a v2-compatible build
export RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=x86-64-v2"