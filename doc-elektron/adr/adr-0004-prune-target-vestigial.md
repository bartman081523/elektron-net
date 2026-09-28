# ADR-0004: Vestigial prune-target machinery in `FindFilesToPrune`

**Status:** Proposed — open design question (architecture scan, question
I1). No decision made yet; see options below.

## Context

`BlockManager::FindFilesToPrune` (`src/node/blockstorage.cpp:322-385`)
still contains the full upstream disk-budget computation, but the fork's
prune loop prunes purely by height ([ADR-0003](adr-0003-mandatory-prune-model.md)).
The disk budget is therefore dead weight — and it currently produces two
unused-variable build warnings:

- `const uint64_t target_sync_height = chainman.m_best_header->nHeight;`
  (`:339`) is declared and never used (verified: single grep hit =
  declaration only).
- `uint64_t nBuffer = BLOCKFILE_CHUNK_SIZE + UNDOFILE_CHUNK_SIZE;`
  (`:354`) is likewise never used; upstream used it in the
  space-based break condition the fork loop no longer has.

Additionally, the remaining `target` value is derived from
`GetPruneTarget()` (`:337-338`) — which comes from the `-prune` user
preference the fork discards (`src/node/blockmanager_args.cpp:36-40`) —
and is only consumed by the debug log at `:381-384`. That log line can
report a `target=…MiB` value that suggests a disk-driven prune which in
this fork never happens.

## Options

1. **Remove the dead machinery (recommended).** Delete the
   `target`/`target_sync_height`/`nBuffer` computation (keeping
   `num_chainstates` only if the historical-chainstate reservation is
   still meaningful for snapshot validation), keep the height-driven
   loop and the log with actual usage instead of a target/diff.
   Behavior-preserving, removes both warnings and the misleading log.
2. **Make the budget meaningful again.** Enforce the mandatory depth as
   a lower bound on retention *and* let a disk budget bound retention
   from above (prune whichever criterion hits first). Changes retention
   behavior and requires deciding what `-prune` means in a fork that
   currently ignores it.
3. **Silence-only.** `(void)`-cast the unused variables. Minimal diff,
   but leaves dead code and the misleading log in place.

## Consequences

Option 1 is a small, reviewable cleanup consistent with the accepted
pruning model; options 2 and 3 are listed for completeness. The choice
between them belongs to the maintainer — see the design issue tracking
this ADR.

**Upstream design issue:** [kutlusoy/elektron-net#57](https://github.com/kutlusoy/elektron-net/issues/57)