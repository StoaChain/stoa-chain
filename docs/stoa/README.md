# StoaChain-specific documentation

Everything in this directory is StoaChain's own. The parent `docs/` directory holds
upstream Kadena documentation — keeping ours here means upstream cherry-picks and
merges never touch these files.

## Contents

| File | What it is |
|---|---|
| [`chainweb-3.2-audit.md`](chainweb-3.2-audit.md) | Full technical audit of `kda-community/chainweb-node` 3.2, every headline claim verified against source |
| [`chainweb-3.2-backport-plan.md`](chainweb-3.2-backport-plan.md) | Wave-by-wave cherry-pick plan, with measured (not estimated) conflict status per commit |

## Status as of 2026-08-02

**The 3.2 upgrade is deliberately on hold.** Chainweb 3.2 pins Pact to
`github.com/kda-community/pact-5-special-fix`, a **private repository**, so the release
cannot be built from source and its Pact security claims cannot be audited. StoaChain is
already on Pact 5.4; the gap is one embargoed patch release.

**Plan:** wait for the Pact 5.4.1 source to be published, then open a dedicated branch and
work the backport plan there.

Watch for publication with:

```bash
git ls-remote https://github.com/kda-community/pact-5-special-fix
git ls-remote --tags https://github.com/kda-community/pact-5 | grep 5.4
```

Either the first command returning refs, or a `5.4.1` tag appearing publicly, is the signal.

## Two things that do not depend on that hold

1. **CVE-2026-9648** (`crypton-x509-validation` ignores X.509 NameConstraints, CVSS 9.1) is
   fixed by a dependency bump with no consensus impact — but our `cabal.project` pin
   `crypton == 1.0.4` currently **blocks** it, because the fixed `crypton-x509-validation-1.9.1`
   requires `crypton >= 1.1`. Our bootstraps carry no pinned certificate fingerprint
   (`domainAddr2PeerInfo = fmap (PeerInfo Nothing)`), so they take the affected system-CA path.

2. **`CLAUDE.md` is wrong about TLS.** It claims `_disablePeerValidation = True` "allows
   self-signed certificates between peers." It does not — that flag only skips
   `validateP2pConfiguration` and permits reserved/RFC1918 peer addresses. It has nothing to
   do with certificate validation.

## Baseline note

StoaChain's real upstream base is `4aedec3bb` ("Forks done right"), which is an **ancestor of
3.2** and is contained in tags 3.1 and 3.2 — **not** 2.32, despite `chainweb.cabal` reading
`version: 2.32.0`. Block header format, RocksDB schema and Pact SQLite schema are all unchanged
between that base and 3.2, so an eventual upgrade is a binary swap, not a resync.
