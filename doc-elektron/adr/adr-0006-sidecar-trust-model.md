# ADR-0006: Trust model of the downloaded `.hash` sidecar

**Status:** Proposed — open design question (architecture scan, question
I3). No decision made yet; see options below. This is the most
consequential of the open snapshot questions and subsumes the anchoring
aspect of [ADR-0005](adr-0005-snapshot-source-selection.md).

## Context

`PopulateAndValidateSnapshot()` (`src/init.cpp:1605-1650`) validates the
coin data of a loaded snapshot against the `.hash` sidecar advertised by
the peer. That makes the sidecar the authoritative integrity anchor —
but the sidecar itself is attacker-supplied data from the first
responding peer ([ADR-0005](adr-0005-snapshot-source-selection.md)).

The obvious stronger anchor — compare the snapshot's UTXO-set hash
against the **on-chain attestation** of the checkpoint block
([ADR-0002](adr-0002-utxo-attestation-gate.md)) — is structurally
blocked by the attestation's computation order:

- The checkpoint block's attestation is computed from the *parent* view
  *before* the `OP_RETURN` is added to the coinbase
  (`src/validation.cpp:2524-2530`, comment at `:2525`).
- Therefore the coinbase that carries the attestation is keyed by its
  *pre-attestation* txid, while the UTXO set the attestation commits to
  is the one keyed by the *post-`OP_RETURN`* coinbase txid.
- A direct on-chain-attestation-vs-sidecar comparison consequently
  never matches (verified structurally during the architecture scan;
  the same construction was attempted live against the running chain
  and was rejected every time).

## Options

1. **Status quo.** Keep the peer-supplied sidecar as the only anchor;
   document the trust model. Cheapest; leaves a hostile single source
   able to feed a self-consistent snapshot.
2. **Attestation transformation (recommended candidate).** Apply the
   deterministic txid correction to the on-chain checkpoint attestation:
   remove the pre-attestation coinbase coin from the attested MuHash
   multiset and add the post-`OP_RETURN` coinbase coin. Both coin
   serializations are locally computable, and MuHash is an
   add/remove-capable multiset hash. The result is the expected
   post-`OP_RETURN` UTXO-set hash, which can be compared directly
   against the sidecar. Needs careful specification of the exact coin
   serialization on both sides of the transformation.
3. **Local reconstruction.** Fetch the checkpoint block itself from the
   P2P network (it is a single block; headers come with normal
   bootstrap), verify its PoW, and recompute the expected attestation
   hash locally — removing the sidecar as a trust anchor entirely.
   Higher cost at bootstrap (one full MuHash computation over the UTXO
   set the snapshot claims), no protocol change.

## Consequences

- Option 1 keeps the fork's threat model simple but trusts a peer for
  the single most important integrity check of the bootstrap path.
- Options 2 and 3 (optionally combined) convert the sidecar from a
  trust anchor into a checked artifact: the expected value would be
  derived from on-chain consensus data, and a mismatching sidecar would
  reject the snapshot instead of validating it.
- Any of these changes affects `PopulateAndValidateSnapshot` and the
  first-responder selection logic; they should be decided together with
  [ADR-0005](adr-0005-snapshot-source-selection.md). See the design
  issue tracking this ADR for the maintainer question.

**Upstream design issue:** [kutlusoy/elektron-net#59](https://github.com/kutlusoy/elektron-net/issues/59)