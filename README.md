# PikaOS v2

A gaming-oriented Linux distribution built on the PikaOS component set,
recompiled and retargeted for **x86-64-v2** hardware — which means it actually
runs on **Sandy Bridge and Ivy Bridge** machines such as the Core i5-3550.

Two desktop editions: **GNOME** and **KDE Plasma**.

---

## Why this exists

Upstream PikaOS compiles its components with:

```
DEB_CFLAGS_MAINT_APPEND="-march=x86-64-v3 -O3 -flto -fuse-linker-plugin"
```

(see `pika-build-config/amd64-v3.sh` in the upstream `pkg-pika-wallpapers`
repo). That is fine for a Haswell-or-newer machine and **fatal** for anything
older: the i5-3550 is Ivy Bridge, which has **AVX but no AVX2, FMA or BMI**.
A v3-targeted binary on that CPU dies with `SIGILL` before `main()`.

This project takes the same PikaOS components and runs the *same* build
pipeline against `config/build-config/amd64-v2.sh`, which is a line-for-line
port of upstream's v3 script with every level pinned to v2:

```
-march=x86-64-v2 -mtune=generic -O3 -flto -fuse-linker-plugin -falign-functions=32
```

For Go components (`pikman`) the equivalent knob is `GOAMD64=v2`.

### The result

| Component | Upstream | Here |
|---|---|---|
| userspace baseline | `x86-64-v3` | **`x86-64-v2`** |
| Go components | `GOAMD64=v3` | **`GOAMD64=v2`** |
| lowest CPU | Haswell (2013) | **Nehalem (2008)** |
| bootloader | rEFInd | **GRUB** (BIOS + UEFI) |

---

## Architecture levels detected at install time

The installer runs a CPU-level detector **before it touches any disk**, so a
user on unsupported hardware is told immediately instead of getting a mystery
crash later.

```
$ pika-cpuidetect
level=v2
model=Intel(R) Core(TM) i5-3550 CPU @ 3.30GHz
vendor=GenuineIntel
v2_ok=1
v3_ok=0
missing_v3=avx2 bmi1 bmi2 fma movbe
verdict=x86-64-v2: this image is a perfect fit. x86-64-v3 packages would SIGILL.
```

| Level | CPU generation | PikaOS v2 | v3 build |
|---|---|---|---|
| `v1` | pre-2008 | may not run | no |
| `v2` | Nehalem (2008) → Ivy Bridge (2012) | **runs** | no |
| `v3` | Haswell (2013)+ | runs | runs |

It reads `/proc/cpuinfo` flags rather than requiring the `cpuid` userspace
tool, so it works on a live session with nothing installed. Note that Linux
reports SSE3 under its historical name `pni`, which the detector accounts for.

---

## Bootloader: GRUB, not rEFInd

Upstream PikaOS ships rEFInd. This image installs **GRUB** instead:

* **UEFI** → `grub-efi-amd64`, installed to the ESP (`--efi-directory=/boot/efi`)
* **BIOS** → `grub-pc`, installed to the disk MBR (`--target=i386-pc`)

The installer detects which firmware mode it booted under via
`/sys/firmware/efi` and picks accordingly. `refind` is explicitly purged if it
ever arrives as a transitive dependency.

The ISO itself is a hybrid image: El Torito BIOS boot via `isolinux`, plus
UEFI boot via a GRUB `BOOTX64.EFI` El Torito image.

---

## Editions

| ISO | Size | Desktop |
|---|---|---|
| `pikaos-v2-gnome-<tag>.iso` | ~3.5G | GNOME 50 + GDM |
| `pikaos-v2-kde-<tag>.iso` | ~4.5G | KDE Plasma 6 + SDDM |

Both carry the PikaOS visual identity: the upstream wallpapers, the
`org.pikaos.breeze-theme` / `org.pikaos.kde-theme` Plasma look-and-feel, the
GNOME GTK-4 theme and assets, and dark-mode defaults.

Live user: **`pika`** / **`pika`**

---

## Building

Everything runs in Docker and is driven by `build.sh`.

```bash
./build.sh image        # build the builder container
./build.sh bootstrap    # stage 10: mmdebstrap a Debian sid rootfs
./build.sh kernel       # stage 20: build the x86-64-v2 kernel
./build.sh base         # stage 30: base system, live user, branding
./build.sh tools        # stage 40: rebuild the PikaOS components at v2
./build.sh gnome        # stage 50: GNOME edition
./build.sh kde          # stage 50: KDE edition
./build.sh installer    # stage 80: detector + installer + GRUB
./build.sh iso          # stage 60: squashfs + hybrid ISOs
./build.sh verify-isa   # stage 70: ISA compliance report
```

Restrict the ISO stage to one edition:

```bash
ONLY_FLAVOURS=kde ./build.sh iso
```

Stages are **resumable**: each writes a marker under `out/state/`, so an
interrupted run resumes instead of restarting. Delete a marker to force a
rebuild.

> Note: the `iso` stage must not be interrupted while `mksquashfs` is running —
> xz compression of a 7G rootfs takes roughly 20 minutes on 4 cores and a
> truncated image is not resumable. The stage reuses an existing squashfs when
> one is present and large enough to be complete.

### Kernel configuration

Built from Debian's `linux` source, based on `x86_64_defconfig` (plain
`defconfig` on 6.16 produces a config with no `CONFIG_NET` at all — a kernel
with no networking), plus `config/kernel/pika-v2.fragment`.

That fragment is verified after every build. The build **fails** if any of
these is missing, because each one is required for this hardware:

`CONFIG_DRM_I915` `CONFIG_SND_HDA_INTEL` `CONFIG_E1000E` `CONFIG_AGP_INTEL`
`CONFIG_ATA_PIIX` `CONFIG_BTRFS_FS` `CONFIG_BLK_DEV_NVME`
`CONFIG_BT_HCIBTUSB` `CONFIG_OVERLAY_FS` `CONFIG_MODULES`

A few symbols were renamed in recent kernels and the fragment tracks the new
names: `BTUSB` → `BT_HCIBTUSB`, `PTP_1588_CLOCK` → `PTP_1588_CLOCK_OPTIONAL`.

---

## Independence from upstream

* `upstream/pikman` has its Go dependencies **vendored in-tree**; the build runs
  with `GOPROXY=off` and `-mod=vendor`, so it never reaches the network and
  never silently picks up a different upstream revision.
* `upstream/pikman/debian/watch` was **removed** (it tracked upstream tags).
* Nothing in `stages/` or `config/` points at `pkg.pika-os.com` or
  `git.pika-os.com`; `sources.list` is plain Debian sid. CI enforces this.
* `pikman`'s Debian dependencies were reduced to what we actually ship
  (`apt-utils`, `flatpak`, `podman`), dropping the PikaOS-only
  `pika-apx-configs` / `vanilla-apx-gui`.

---

## CI

`.github/workflows/ci.yml` runs fast checks on every push — deliberately no
full ISO build, since the rootfs alone exceeds a runner's ephemeral disk:

* kernel fragment applies and keeps every Ivy Bridge driver
* no `x86-64-v3` / `mavx2` / `mfma` flag anywhere in the v2 build config
* `pikman` builds offline and contains no above-v2 instructions
* no reference to the PikaOS upstream apt repo
* `shellcheck` over all stages and scripts
* QEMU boot smoke test when an ISO is present

---

## Layout

```
build.sh                  build driver
config/
  pika.conf               version, target arch, flavours
  build-config/
    amd64-v2.sh           the v2 port of upstream's amd64-v3.sh
    i386.sh               32-bit (Steam/Proton) build flags
  kernel/pika-v2.fragment kernel tuning
  pika-cpuidetect         x86-64 level detector
  pika-install            installer (detector gate + GRUB)
stages/                   10,20,30,40,50,60,70,80
upstream/                 vendored PikaOS components
.github/workflows/ci.yml
```

## License

The vendored upstream components keep their original licenses (mostly MIT).
This build system is MIT.