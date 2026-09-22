# ADR-0005: Snapshot source selection — first responder wins

**Status:** Proposed — open design question (architecture scan, question
I2). No decision made yet; see options below. Builds on
[ADR-0001](adr-0001-snapshot-bootstrap.md).

## Context

A serving node advertises snapshot availability (`NODE_SNAPSHOT`,
`src/init.cpp:1434`) by sending a `UTXOSNAPSHOT` advertisement. In
`src/net_processing.cpp:5415-5440`, the **first** peer whose advertisement
passes the gates initiates the download state — including the advertised
`utxo_hash` that becomes the `.hash` sidecar. Later advertisements for
the same checkpoint are not used to initialize another download (guarded
by a count check on the existing download tracker); once a final
snapshot file exists, re-advertisement cannot re-initialize the download
either.

The result: whichever peer responds first effectively decides the bytes
a bootstrapping node will validate against. The coin data are validated
against the sidecar (`PopulateAndValidateSnapshot`, `src/init.cpp:1605-1650`),
but the sidecar itself originates from that same first responder — the
trust implications are tracked separately in
[ADR-0006](adr-0006-sidecar-trust-model.md).

## Options

1. **Status quo.** First responder wins; internal consistency checks
   (coin data vs. sidecar) only. Simplest, but a single fast or
   well-positioned peer is the sole source of the snapshot a node
   consumes, and a hostile peer can serve a self-consistent but false
   snapshot/sidecar pair.
2. **Redundant sidecar cross-check.** Before activation, fetch the
   sidecar hash for the same checkpoint from additional advertisers
   (peers advertising `NODE_SNAPSHOT` for the same checkpoint hash) and
   require agreement. Moderate protocol cost; meaningfully raises the
   bar against a hostile single source without changing snapshot
   activation logic.
3. **On-chain anchoring.** Anchor the expected sidecar value to the
   checkpoint block's attestation instead of to peer-supplied data —
   the strongest option, described with its structural obstacle in
   [ADR-0006](adr-0006-sidecar-trust-model.md).

## Consequences

- Under option 1, snapshot integrity is peer-trust-based in practice;
  the fork's threat model should say so explicitly.
- Options 2 and 3 are compatible with each other and with the existing
  download state machine (they add a verification step before
  activation, they do not change the wire protocol's chunked transfer).

The choice depends on how far the project wants to push snapshot
verification without a maintainer-facing change to the attestation
design — see the design issue tracking this ADR.

**Upstream design issue:** [kutlusoy/elektron-net#58](https://github.com/kutlusoy/elektron-net/issues/58)