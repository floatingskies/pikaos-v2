# PikaOS-v2 package builder (Debian sid + the audited PikaOS packaging toolchain).
#
# Mirrors repo-tools/docker-images/pika-builder, but pinned to a plain Debian
# sid base (v2-safe baseline) instead of the v3 PikaOS nest, and with deb-src
# enabled so package main.sh scripts can run `apt-get build-dep ./` and
# `apt-get source`. The v2 ISA is injected per-build via pika-build-config.sh
# (see ../build-config/amd64-v2.sh) -- this image sets no -march itself.
FROM debian:sid

ENV DEBIAN_FRONTEND=noninteractive

# deb-src for apt-get build-dep / apt-get source (PikaOS publishes no sources).
RUN printf '%s\n' \
      'deb http://deb.debian.org/debian sid main contrib non-free non-free-firmware' \
      'deb-src http://deb.debian.org/debian sid main contrib non-free non-free-firmware' \
      > /etc/apt/sources.list

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      debhelper \
      dh-make \
      fakeroot \
      dpkg-dev \
      devscripts \
      equivs \
      quilt \
      autoconf \
      automake \
      libtool \
      pkg-config \
      cmake \
      meson \
      ninja-build \
      gettext \
      intltool \
      python3 \
      python3-setuptools \
      python3-pip \
      git \
      ca-certificates \
      curl \
      wget \
      rsync \
      xz-utils \
      zstd \
      lz4 \
      cpio \
      bc \
      bison \
      flex \
      kmod \
      libelf-dev \
      libssl-dev \
      libncurses-dev \
      libdevmapper-dev \
      golang-go \
      ronn \
      gnupg \
      apt-utils \
      jq \
      sudo \
      locales \
      libgbm-dev \
      libdrm-dev \
      mesa-common-dev \
      libsystemd-dev \
      systemd-dev \
      libgudev-1.0-dev \
      gir1.2-gudev-1.0 \
      qtbase5-dev \
      qttools5-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Force C.UTF-8 so package builds are locale-stable.
RUN sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

WORKDIR /work
CMD ["/bin/bash"]
