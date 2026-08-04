# Tailscale source patches

The tiny `tailscaled` builds published by this repository are compiled from unmodified
Tailscale release tags plus the patches in this directory. `.github/workflows/build-tailscale.yaml`
applies them through `scripts/apply-tailscale-patches.sh` before `go build`.

The build resolves its Tailscale tag from `releases/latest` and is only triggered when
that tag is *newer* than our last release — i.e. exactly when the source has moved
underneath these patches. Everything here is built around that fact.

**Last rebased and built against: `v1.102.1`** (`PATCHES_TESTED_TAG` in
`scripts/apply-tailscale-patches.sh` — bump it together with the patches).

## Contents

| File | Target | Purpose |
|---|---|---|
| `0002-nft-connmark-restore-gl-coexist.patch` | `util/linuxfw/nftables_runner.go` | PREROUTING connmark restore writes the **full** ct mark to the skb instead of `ct mark & 0xff0000`, so GL policy-routing bits (0x8000) survive. |
| `verify/gl_invariants_test.go` | copied to `util/linuxfw/zz_gl_invariants_test.go` | Asserts the end state of *all* patches, current and retired. Not a patch — the apply script never picks it up. |

Only files matching `[0-9][0-9][0-9][0-9]-*.patch` directly in this directory are applied.

### Retired

`0001-fix-nftables-fwmark-endianness.patch` — nftables fwmark mask bytes must be
native-endian ([tailscale/tailscale#11803](https://github.com/tailscale/tailscale/issues/11803)).
**Tailscale fixed this itself in v1.100.0**, using a `nativeEndianUint32` helper in
`util/linuxfw/linuxfw.go`. Because the patch's import hunk (`"encoding/binary"`) became
byte-identical to upstream, `patch` started reporting

```
Reversed (or previously applied) patch detected!  Assume -R? [n]
Apply anyway? [n]
Skipping patch.
2 out of 2 hunks ignored
```

and exited 1, killing all seven matrix legs. The patch was removed; the behaviour it
provided is now guarded by `verify/gl_invariants_test.go` instead, so an upstream revert
would still be caught.

## How the apply step behaves

`scripts/apply-tailscale-patches.sh` runs each patch through `patch -p1 --forward --batch`
with a dry run first, and classifies the outcome:

- **applies cleanly** → applied, logged as `applied:`
- **reversed, no failed hunk** → Tailscale adopted the change; skipped with a warning.
  That is your signal to retire the patch (see below).
- **anything else**, including a mix of applied and reversed hunks → hard failure, with
  the dry-run output and the `.rej` contents printed.

Afterwards it asserts the end state textually in the source, on **every** matrix leg, so
a skipped or misplaced hunk cannot quietly produce a binary without the GL.iNet
behaviour. The workflow additionally runs `verify/gl_invariants_test.go` once (amd64
leg) as the authoritative structural check.

A build against a tag other than `PATCHES_TESTED_TAG` only warns. The floating "latest"
resolution is supposed to keep flowing; the assertions are the hard gate.

## Retiring a patch

When the apply step reports `already applied upstream, skipping: <patch>` **and** the
invariant test passes, Tailscale has taken the change over. Delete the patch file and
leave the corresponding assertion in `verify/gl_invariants_test.go` in place — it is what
turns a future upstream revert back into a build failure instead of a silent regression.

## Rebasing a patch

```sh
git clone --depth 1 --branch v1.102.1 https://github.com/tailscale/tailscale ts && cd ts
# make the change by hand
git diff -U3 -- util/linuxfw/nftables_runner.go > 0002-nft-connmark-restore-gl-coexist.patch
```

Then prepend the `#` comment header (GNU `patch` skips leading non-diff text) and bump
`PATCHES_TESTED_TAG`. Keep patches minimal and anchored on **code**, not on prose:
upstream rewrites doc comments freely, and a patched comment is a build break waiting to
happen. `0002` deliberately touches neither the `makeConnmarkRestoreExprs` doc comment
nor any test fixture.

Verify locally before pushing:

```sh
TS_TAG=v1.102.1
git clone --depth 1 --branch "$TS_TAG" https://github.com/tailscale/tailscale ts && cd ts
TAILSCALE_TAG=$TS_TAG ../scripts/apply-tailscale-patches.sh --patch-dir ../patches
cp ../patches/verify/gl_invariants_test.go util/linuxfw/zz_gl_invariants_test.go
go test ./util/linuxfw/ -run TestGLPatchInvariants -v
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o /dev/null tailscale.com/cmd/tailscaled
CGO_ENABLED=0 GOOS=linux GOARCH=mips GOMIPS=softfloat go build -trimpath -o /dev/null tailscale.com/cmd/tailscaled
```

Build one little-endian and one big-endian target — mips is where the fwmark byte order
actually differs.

## Golden test fixtures

`0002` intentionally does **not** patch the golden netlink byte fixtures in
`util/linuxfw/nftables_runner_test.go`. Those are ~1.4 KB single-line `\xNN` strings with
three lines of context; they were the most fragile part of the old patches, and the build
workflow never runs `go test`, so in CI they bought nothing.

Consequence: in a patched tree `go test ./util/linuxfw/ -run TestMakeConnmarkRestoreExprs`
**fails by design**. `go test ./util/linuxfw/ -run TestGLPatchInvariants` is the check that
matters. `TestNFTAddAndDelConnmarkRules` still passes — it inspects rule objects rather
than golden bytes.

To regenerate the fixture anyway, two mechanical edits to the `want` string of
`TestMakeConnmarkRestoreExprs`:

1. `\x48\x01\x04\x80` → `\x68\x01\x04\x80` (the `NFTA_RULE_EXPRESSIONS` length grows from
   328 to 360 — one more 32-byte expression)
2. insert, immediately before the trailing `meta` chunk, this 32-byte chunk — it is
   byte-identical to the "Load conntrack mark into register 1" chunk already present
   earlier in the same string, so copy it rather than typing it:

   ```
   \x20\x00\x01\x80\x07\x00\x01\x00\x63\x74\x00\x00\x14\x00\x02\x80\x08\x00\x02\x00\x00\x00\x00\x03\x08\x00\x01\x00\x00\x00\x00\x01
   ```

and drop the trailing `& 0xff0000` from the adjacent comment. Confirm by running the test
rather than trusting the arithmetic.

## Note on prereleases

`.github/workflows/build-prerelease.yaml` builds the same Tailscale tag but applies **no**
patches at all — it does not even check this repository out. Prerelease binaries are
therefore stock Tailscale and do not contain the connmark coexistence change.
