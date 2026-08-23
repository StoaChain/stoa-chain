# Miner fork voting — how it works, and how to adopt it for StoaChain

Upstream design write-up: [Kadena — On-chain voting for miners](https://medium.com/@communitykadena/kadena-on-chain-voting-for-miners-on-the-way-to-decentralization-2bc0047df3d2)
Live tracker for Kadena mainnet: <https://fork.kda-chain.org>

Everything below was read out of the source at tag `3.2.1`, not from the articles.

---

## 1. The core idea

Instead of a developer picking a block height at which new rules activate, the network activates them when **two thirds of the blocks mined over a five-day window signal support**. Nobody schedules the fork; the chain forks itself when the hashpower says so.

The whole mechanism rides in a header field that already existed and was always zero.

## 2. Where the vote lives

Chainweb's block header has always carried an 8-byte `featureFlags` field, reserved and required to be zero. 3.x renames it `ForkState` and gives it meaning. **No field was added — the header layout, header size, and Merkle tag `0x0006` are all unchanged.** That is why adopting this is not a wire-format break.

```
ForkState :: Word64
  bits  0-31  ForkNumber  -- which ruleset this block was built under
  bits 32-63  ForkVotes   -- accumulated vote counter
```

`src/Chainweb/ForkState.hs` — `_forkNumber (ForkState w) = int $ w .&. 0xFFFFFFFF`, `_forkVotes (ForkState w) = int $ (w \`shiftR\` 32) .&. 0xFFFFFFFF`.

Votes are quantised: one vote is `voteStep = 1000`, not 1. That leaves room for the averaging step in §4 without losing precision to integer truncation.

## 3. How a miner votes

A miner does not send a vote message. **Winning a block *is* the vote.** When a node builds work for a miner, `newForkState` decides what to write into the header:

```haskell
-- src/Chainweb/BlockHeader/Internal.hs
newForkState as p targetFork
    | isForkEpochStart v h = cur & forkVotes .~ (if vote then addVote resetVotes else resetVotes)
                                 & forkNumber %~ (if decideVotes v curVotes then succ else id)
    | isForkVoteBlock  v h = cur & forkVotes %~ (if vote then addVote else id)
    | otherwise            = cur & forkVotes .~ countVotes allParentVotes
  where
    vote = curNumber < targetFork
```

`vote` is true whenever the chain's current fork number is behind what this node's binary supports. So **voting yes is the default** — you vote for a fork simply by running a version that knows about it. Opting out is explicit:

```
--mining-target-fork-override      # "do not vote for the next fork number increment"
```

(`src/Chainweb/Miner/Config.hs`; JSON key `mining.coordination.targetForkOverride`, default `false`.)

Two consequences worth internalising:

- **The vote is per *node*, not per miner.** Every external miner pulling work from a coordinator inherits that node's setting, resolved once at startup.
- **One vote costs one full proof-of-work block.** `Validation.hs` caps the per-block delta at exactly 0 or +1000, so votes cannot be bought below the price of hashrate.

## 4. The five-day cycle

A **fork epoch** is 14,400 block heights per chain, split into two phases:

| Phase | Length | What happens |
|---|---|---|
| Vote casting | **14,280** blocks (`120 * 119`) | each mined block may add one `voteStep` |
| Vote counting | **120** blocks | blocks stop adding votes and instead average across chains |

At the 30-second block delay: 14,400 x 30 s = 432,000 s = **exactly 5 days**. Note this is a *block count*, so a hashrate drop stretches the wall-clock duration.

The counting phase exists because each chain accumulates its own tally. During the last 120 blocks each new block overwrites its vote field with the mean of its parent's and its adjacent parents' fields:

```haskell
countVotes votes = sum votes `quot` ForkVotes (int $ length votes)
```

Braiding propagates that average across the graph so all chains converge on a network-wide figure.

## 5. Activation

```haskell
-- src/Chainweb/Version.hs
voteCountingLength  = 120
forkEpochLength v   = _versionForkVoteCastingLength v + voteCountingLength
decideVotes v votes = round (votes % voteStep) * 3 >= _versionForkVoteCastingLength v * 2
```

The threshold is `round(votes/1000) * 3 >= 14280 * 2`, i.e. **>= 9,520 of 14,280 = exactly 2/3**. (Exact only because 14,280 divides by 3.)

At the first block of the next epoch, if the threshold was met, the fork number increments by one — and **incrementing is mandatory**. `prop_block_forkNumber` rejects a block that fails to increment when `decideVotes` holds. A miner cannot veto a passed vote by refusing to bump.

Other rules the validator enforces:

- a block signalling `forkNumber > parent + 1` is **invalid** — forks activate strictly one at a time, with at least one full epoch between them
- vote counts may only stay equal or increase by one step within an epoch
- a node rejects any block whose fork number exceeds what its own binary supports (`prop_block_forkKnown`), so an un-upgraded node **stalls** rather than following a fork it does not understand

**Important caveat:** monotonicity holds along a single chain's history. A deep reorg past an epoch-start block can restore the previous fork number. "Once activated, never deactivated" should read "except by reorg."

## 6. Wiring a fork to the vote

A fork is vote-gated by keying it on a fork number instead of a height:

```haskell
Chainweb32 -> AllChains (ForkAtForkNumber 1)     -- vote-gated
Chainweb31 -> AllChains (ForkAtBlockHeight 6_510_742)  -- height-gated
```

`ForkHeight` gained a constructor for this, with a hand-written ordering where `ForkAtGenesis < ForkNumber 0 < any BlockHeight < ForkNumber >= 1 < ForkNever`. Once the on-chain fork number reaches 1, block height stops mattering for every rule keyed this way.

`_versionForkNumber` on the version record is the **ceiling** — the highest fork this binary knows about, and therefore the highest it will vote for.

## 7. The tracker page

<https://fork.kda-chain.org> is a small read-only web page, not part of the node. It polls a public chainweb API every 30 seconds, reads the `featureFlags` value out of the latest cut's headers, splits it into fork number and vote count, and renders the percentage against the 66.7% line.

Everything it needs is already exposed by any node's service API — the cut endpoint returns headers, and the header JSON carries `featureFlags` (plus derived `forkNumber` / `forkVotes` in the extended encoding). **An equivalent tracker for StoaChain is a small standalone page against our own service port (1848); it requires no node changes.**

---

## 8. Adopting this for StoaChain

### What we already have

`src/Chainweb/ForkState.hs` in our tree is **byte-identical** to upstream's, and our block header already carries the `ForkState` field. `Stoa.hs` already sets `_versionForkNumber = 0`. The scaffolding is in place; what we lack is the activation logic, which lives in the ForkNumber refactor (`7d02e2a2f` and follow-ups).

### What `Stoa.hs` needs

| Field | Value | Note |
|---|---|---|
| `_versionForkVoteCastingLength` | `120 * 119` | 5-day epoch at our 30 s block delay — same as every upstream version |
| `_versionForkNumber` | `0`, then `1` when we ship a fork | the ceiling this binary votes for |
| `_versionSpvProofRootValidWindow` | `Bottom (minBound, Nothing)` | renamed from `_versionMinimumBlockHeaderHistory`; keep expiry off |
| `Chainweb31`, `Chainweb32` | **explicit**, never the wildcard | see the warning below |

> **Do not leave `Chainweb31` / `Chainweb32` on the wildcard `_ -> AllChains ForkAtGenesis`.** `ForkAtGenesis` is `minBound`, so `chainweb32` would read as always-true and retroactively apply the new Pact semantics to our entire history. Set them explicitly.

### Does voting even make sense for a chain we control?

Honestly: as a *governance* mechanism, no — we run the miners, so a vote we call always passes. Its value for StoaChain is **operational**:

- it gives a clean, self-scheduling activation path, so we never have to pick a block height and hope every node is upgraded by then
- an un-upgraded node stalls loudly instead of silently forking off
- it is the mechanism upstream now uses to gate everything, so staying aligned makes future ports mechanical

Every adversarial weakness in the design (vote grinding by mining chain order, cross-chain convergence, reorg reversal) is a many-miner, 20-chain problem. On a 10-chain network with our own miners, `_versionForkVoteCastingLength` is simply a knob — and for testing we can set it far lower than `120 * 119` to make an epoch minutes rather than days.

### Sequencing note

Voting depends on the ForkNumber refactor, which is also the cleanest way to gate the Pact 5.4.1 security fixes. If we adopt Wave 4 of the backport plan for the security fixes, voting comes almost for free afterwards.
