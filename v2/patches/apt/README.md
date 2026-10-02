# apt

Upstream patches for apt.

`apt-fast.patch` — performance patchset over upstream apt **3.3.3** (latest sid
tag at creation). 49 upstream commits squashed into one clean `-p1` diff,
verified to apply to a pristine 3.3.3 tree (both `patch -p1` and `git apply`)
and to reproduce the source branch byte-identically. Upstream test suite on the
patched tree: 344 run / 338 pass / 0 fail / 6 skip (the skips are upstream's
own `solver3.broken` set).

What it contains, in five series:

1. **Hash verification** — compute only the strongest trusted hash per
   download instead of every hash the archive lists (−54% download-path CPU;
   verification strength unchanged; opt-out `Acquire::ComputeAllHashes`).
2. **apt update / cache generation** — parallel store/gpgv/sqv methods,
   geometric cache-mmap growth, hoisted per-stanza config lookups, deb822
   `.sources` timestamp fix, and an update that fetched nothing keeps its
   caches (no-change `apt update`: 2.3 s → 0.02 s at a 290 MiB cache;
   opt-out `APT::Update::Always-Rebuild-Caches`).
3. **solver3** — fixes a latent SIGABRT on timeout-during-setup, makes
   `APT::Solver::Timeout` actually enforced (steady clock, honest elapsed
   message naming the last real conflict), stops building discarded
   explanations while backtracking, 5.5× faster `apt -s full-upgrade`
   (byte-identical output), −13–25% instructions on real resolves at
   PikaOS scale, plus a symbols-file correction for `InternalCliWhy`.
4. **Parallel per-host connections** — `Acquire::QueueHost::Connections`
   (default 3), multi-worker host queues with spawn-failure recovery (fixes a
   pre-existing upstream hang), process/fd caps, SRV lookup dedup + timeout
   cap, warm-up connection against resolver stampedes.
5. **HTTP/2 transport** — new `apt-transport-curl` binary package
   (libcurl-multi, one connection × 10 multiplexed streams via `curl+https://`
   sources; stock apt sends no ALPN at all). Core apt builds without libcurl;
   `pkg.apt.nocurl` profile supported. Shared redirect policy with the
   built-in method, full proxy/auth/resume parity.

Final blind A/B on a PikaOS chroot with real fsync, levelled package sets and
byte-equivalence checks: apt update −18% wall, download −22% wall / −39% CPU,
install −13%, dependency solve 2.5× — with identical results throughout.
