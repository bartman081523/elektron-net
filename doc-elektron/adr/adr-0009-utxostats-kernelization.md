# ADR-0009: Decoupling `ComputeUTXOStats` from `node::BlockManager`

**Status:** Proposed — open design question (follow-up to upstream PR
#50, *"kernel: break kernel/coinstats <-> validation include cycle"*).
No decision made yet.

## Context

PR #50 removed the direct include cycle between `kernel/coinstats` and
`validation`, but the kernel layer still reaches into node-layer state:
the `ComputeUTXOStats` worker takes a `node::BlockManager&` parameter
(`src/kernel/coinstats.cpp:130`, public overload at `:161-174`). The
kernel directory is meant to be the bottom layer of the dependency
stack, so this parameter keeps a layering inversion alive even after the
include cycle itself is gone.

## Options

1. **Narrow the interface.** Replace the `BlockManager&` parameter with
   the smallest set of capabilities `ComputeUTXOStats` actually needs
   (e.g. a callback or small view exposing block-file height data) and
   let the node layer supply it. Restores kernel purity; requires
   auditing which BlockManager data the function touches.
2. **Lift the block-derived inputs.** Have the caller in the node layer
   precompute everything BlockManager-dependent and pass plain values
   into the kernel function. No kernel-layer interface change, but may
   force the node layer to duplicate traversal logic.
3. **Accept and document.** Keep the parameter and document the known
   layering exception in the kernel module. Cheapest; the inversion
   stays.

## Consequences

- Option 1 matches the direction the kernel/ directory in upstream
  Bitcoin Core has been moving (kernel purity, explicit interfaces).
- The practical scope is small: the coinstats call sites are few, and
  the function already receives its hash object and interruption point
  as parameters — the BlockManager dependency is the last node-layer
  type in the signature.
- Whichever option is chosen should be decided together with the
  maintainer's appetite for further kernel-layer refactors; PR #50 is
  the natural vehicle for follow-up discussion.

See the design issue tracking this ADR.

**Upstream design issue:** [kutlusoy/elektron-net#62](https://github.com/kutlusoy/elektron-net/issues/62)