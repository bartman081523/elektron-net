# ADR-0007: Conflicted-coinbase assert in wallet maturity accounting

**Status:** Proposed — open design question (architecture scan, question
I4). No decision made yet; reachability needs verification first.

## Context

Wallet maturity accounting assumes a coinbase transaction can never be
conflicted:

- `CWallet::GetTxDepthInMainChain` returns a **negative** depth exactly
  when the wallet transaction is `TxStateBlockConflicted`
  (`src/wallet/wallet.cpp:3450-3458`).
- `CWallet::GetTxBlocksToMaturity` then asserts
  `chain_depth >= 0` with the comment *"coinbase tx should not be
  conflicted"* (`src/wallet/wallet.cpp:3461-3471`, assert at `:3469`).

But the conflicted state is reachable in principle: when a confirmed
block contains a transaction that conflicts with a wallet transaction,
`CWallet::AddToWalletIfInvolvingMe` marks the losing wallet transactions
conflicted (`src/wallet/wallet.cpp:1233-1244`), and
`CWallet::MarkConflicted` propagates the state recursively to
descendants (`src/wallet/wallet.cpp:1365-1393`). A mined coinbase on a
reorged-out tip is the textbook case.

Consequences if a conflicted coinbase ever reaches this path:

- **Debug builds abort** on the assert.
- **Release builds** compute `std::max(0, (COINBASE_MATURITY+1) -
  negative_depth)` (`COINBASE_MATURITY = 100`,
  `src/consensus/consensus.h:19`) — i.e. a permanently immature
  coinbase, which is arguably the safe outcome but only by accident.

## Open question

Is `TxStateBlockConflicted` on a coinbase actually reachable in this
fork (reorg of a wallet-mined coinbase, snapshot-bootstrapped wallet
rescans, wallet restore across a reorg)? The assert currently encodes an
unverified invariant.

## Options

1. **Verify reachability first (recommended).** Construct or disprove a
   concrete scenario (wallet-mined coinbase whose block is reorged away).
   The result determines the correct fix.
2. **If reachable — replace the assert with defined behavior.** Treat a
   conflicted coinbase as immature (documented) or as a distinct state,
   instead of aborting debug builds.
3. **If unreachable — keep the assert and codify it.** Keep the assert
   as a cheap invariant check and add a test/documentation pinning why
   the state is unreachable (e.g. coinbase spend rules preclude
   conflicting spends in the same wallet before maturity).

## Consequences

This is an inherited-upstream latent issue, not fork-specific logic —
but the fork's mandatory pruning and snapshot bootstrap widen the
rescan/reorg paths wallets can encounter, so the invariant is worth
verifying here. See the design issue tracking this ADR.