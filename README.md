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

The image is built in CI; `pipeline.yml` runs the whole chain
(builder images -> package fleet -> apt index -> ISO -> Pages).

```bash
gh workflow run pipeline.yml -f recipe=full -f push_images=true
```

To build one ISO locally, after `v2/repo/pool/main` has debs (the CI step
"Upload built debs" or `v2/pkg-build.sh` for each package):

```bash
./iso-v2/make-iso.sh full          # containerised, needs root and ~20G free
./iso-v2/qemu-test.sh              # boot it under OVMF and dump the serial log
```

`v2/pkg-build.sh <org>/<name>` builds a single package. It skips the build
when the upstream commit and our injected build inputs (the v2 ISA flags and the
dependency shims) are unchanged since the last successful build, so iterating on
one package does not rebuild the fleet.

---

## Independence from upstream

* Packages are rebuilt from `git.pika-os.com` with their upstream names intact,
  so they stay trackable against upstream; nothing is forked silently.
* The image itself needs no PikaOS apt repo: `sources.list` is plain Debian sid
  (plus `deb-multimedia` for `libdvdcss2`, which Debian does not package for
  amd64). CI enforces both.
* `pikman`'s Debian dependencies were reduced to what we actually ship
  (`apt-utils`, `flatpak`, `podman`), dropping the PikaOS-only
  `pika-apx-configs` / `vanilla-apx-gui`.

---

## CI

`.github/workflows/ci.yml` runs fast checks on every push — deliberately no
full ISO build, since the rootfs alone exceeds a runner's ephemeral disk:

* kernel fragment applies and keeps every Ivy Bridge driver
* no `x86-64-v3` / `mavx2` / `mfma` flag anywhere in the v2 build config
* the CPU level detector classifies v1/v2/v3 correctly
* the installer targets GRUB for both UEFI and BIOS and never rEFInd
* no reference to the PikaOS upstream apt repo
* `shellcheck` over the image build, the installer and the v2 tooling

The package fleet, the ISO and the boot smoke test live in `pipeline.yml`,
because they need the builder images and the full disk a runner only has once.

---

## Layout

```
config/
  pika.conf               version, target arch, flavours
  build-config/
    amd64-v2.sh           the v2 port of upstream's amd64-v3.sh
    i386.sh               32-bit (Steam/Proton) build flags
  kernel/pika-v2.fragment kernel tuning
  pika-cpuidetect         x86-64 level detector
  pika-install            installer (detector gate + GRUB)
iso-v2/                   the v2 live ISO build (GRUB2 + Debian live-boot)
v2/                       x86-64-v2 package fleet, build cache and apt index
.github/workflows/ci.yml  fast checks on every push
.github/workflows/pipeline.yml  images -> packages -> repo -> ISO
```

## License

The vendored upstream components keep their original licenses (mostly MIT).
This build system is MIT.