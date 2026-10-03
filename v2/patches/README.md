# Upstream performance patches

Performance patches for tools that are **not** PikaOS packages.

| Patch | Target | Status |
|---|---|---|
| `apt/apt-fast.patch` | upstream apt 3.3.3 | written, not built |
| `dpkg/dpkg-fast.patch` | upstream dpkg 1.23.7 | written, not built |

Both directories carry their own README with the patch contents and the test
results from when they were written.

## Why they are not in `v2/ci/packages.tsv`

`v2/pkg-build.sh` builds a package by cloning `<org>/<name>` from
`git.pika-os.com` and running its `main.sh`. These patches have no such repo:
apt and dpkg are Debian's, and the point of the patchsets is to be applied to a
pristine upstream tree. There is nothing to clone and no PikaOS `main.sh` to
run, so listing them in the fleet would only produce a clone failure.

## Why they are not wired in

Nothing references them today. That is a deliberate gap, not an oversight, and
it should stay a gap until these three things are true.

**1. They must be rebuilt and verified, not just applied.** A patchset that has
been `patch -p1`'d into a tree is not a package. Producing a real `apt`/`dpkg`
deb means carrying the Debian packaging, signing the result, and getting it
into the image's apt pool. There is currently no step that does this.

**2. dpkg's failure mode is not acceptable by default.** The dpkg patchset's
headline change is a *digest skip*: stop MD5-hashing extracted files whose
digest nothing consumes. That is correct for the overwhelmingly common case
(packages ship their own `md5sums`), and it is a real speedup on install. But
dpkg is the thing that verifies what lands on disk. An image whose dpkg is
patched to hash less, produced by a script that has never been audited end to
end, is a supply-chain-shaped problem, not a performance win. `apt-fast` is far
lower risk because apt's verification is about the *download* and this leaves
strength unchanged, but it has the same "never actually built" status.

**3. Neither has been tested on the image's actual package set.** Both READMEs
report the *upstream* test suites passing (apt: 344 run / 338 pass / 0 fail;
dpkg: unit TAP 3989, autotest 74, functional 84). That is necessary and not
sufficient: the question that matters here is whether a full debootstrap and
install of the ISO recipe still succeeds and produces an identical rootfs, and
nobody has run that.

## What "done" looks like

1. A build script that clones the matching Debian source (`apt` and `dpkg` are
   in Debian, so `apt-get source apt` against sid), applies the patch, and
   builds with `dpkg-buildpackage`.
2. The resulting debs land in `v2/repo/pool/main`, so they flow through
   `repo-index.sh` and into the ISO's apt pool like any other v2 package.
3. The kernel/ISA story is handled: these are C++ (apt) and C++/C (dpkg), so
   `amd64-v2.sh` applies, and the same `-march=x86-64-v2` check that guards the
   kernel should cover them.
4. A boot smoke test that installs them and diffs the resulting rootfs against a
   control image, to catch the case where a "faster" dpkg changes behaviour
   rather than only speed.
5. `pipeline.yml` gates on that diff.

Until then these live here as reviewed, tested-in-isolation source patches, and
the image ships Debian's own apt and dpkg.