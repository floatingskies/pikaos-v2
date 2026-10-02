# dpkg

Upstream patches for dpkg.

`dpkg-fast.patch` — performance patchset over upstream dpkg **1.23.7** (latest
sid tag at creation). 13 upstream commits squashed into one clean `-p1` diff,
verified to apply to a pristine 1.23.7 tree, build, and reproduce the source
branch byte-identically. Full upstream suites green (unit TAP 3989, autotest
74, functional 84 incl. device-node tests) in both io_uring and fallback
modes; on-disk results byte-identical across three package corpora.

What it contains:

- **Digest skip** — stop MD5-hashing every extracted file whose digest is
  never used (packages shipping their own md5sums, i.e. nearly all).
- **Files-list invalidation fix** — reload only the lists actually
  invalidated instead of the whole database per package.
- **Cross-package read-ahead** — decompress the next archive while unpacking
  the current one (gated on CPU count via `sched_getaffinity`, disabled under
  debsig verification).
- **io_uring batched fsync barrier** — the deferred per-file fsyncs
  (15 671 calls on a 371-package install) are submitted as batched rings
  (554 submissions). Durability is strictly stronger than upstream: every
  file of a batch is durable before any of its renames. Runtime-detected with
  a verbatim fallback to the current code path where io_uring is unavailable
  (container seccomp returns ENOSYS/EPERM).
- **`--force-unsafe-io` widened** (opt-in flag only; status-database journal
  fsyncs deliberately kept unconditional; documented in dpkg.pod). Default
  durability is provably unchanged: identical fsync counts to upstream.

Final blind A/B on a PikaOS chroot (real fsync, native io_uring, 371 real
PikaOS packages, unpack + configure with 83% maintainer-script coverage):
**−14.6% wall** (IQR 0.820–0.890, results byte-identical). Unpack-only with
`--force-unsafe-io`: −36% wall, −13% CPU.
