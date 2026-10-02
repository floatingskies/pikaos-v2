FROM debian:sid

ENV DEBIAN_FRONTEND=noninteractive

RUN rm -f /etc/apt/sources.list.d/debian.sources \
 && printf '%s\n' \
      'deb http://deb.debian.org/debian sid main contrib non-free non-free-firmware' \
      > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      debootstrap \
      mmdebstrap \
      dpkg-dev \
      apt-utils \
      xorriso \
      mtools \
      dosfstools \
      grub-common \
      grub-efi-amd64-bin \
      squashfs-tools \
      ca-certificates \
      zstd lz4 xz-utils \
      busybox-static \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
