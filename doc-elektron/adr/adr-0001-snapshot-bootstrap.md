# ADR-0001: UTXO snapshot bootstrap path

**Status:** Accepted — documents the snapshot bootstrap behavior present in
the tree as of upstream `main` (`447c069`). Related open design questions:
[ADR-0005](adr-0005-snapshot-source-selection.md) (source selection),
[ADR-0006](adr-0006-sidecar-trust-model.md) (sidecar trust model).

## Context

Mainnet retains roughly 137 days of blocks (`MANDATORY_PRUNE_DEPTH = 197280`,
`src/validation.h:84`), so a fresh node cannot bootstrap by replaying the
full chain. The fork instead bootstraps from UTXO snapshots that nodes
write automatically after each checkpoint block
(`WriteAutomaticSnapshot`, `src/validation.cpp:2555`, called once per
checkpoint interval) and exchange over the P2P wire
(`getutxosnap` / `utxosnapshot` / `getsnapdata` / `snapshotdata`,
`src/protocol.h:278-294`).

A serving node advertises availability via the `NODE_SNAPSHOT` service
flag (`src/init.cpp:1434`) and sends a `UTXOSNAPSHOT` advertisement
carrying the checkpoint hash, height, total file size and the UTXO-set
MuHash of the snapshot (`utxo_hash`, `src/net_processing.cpp:5415-5440`).

## Decision

The bootstrap path as implemented:

1. **Receive + gate.** A bootstrapping node accepts a `UTXOSNAPSHOT`
   advertisement only while it is a legitimate snapshot consumer: the
   advertised checkpoint hash must match the node's own bootstrap target
   and the node must be in initial block download, holding an invalid
   chain, or fallen behind its prune horizon
   (`src/net_processing.cpp`, `m_snapshot_bootstrap_target` gate).
   The advertised file size is clamped by `MAX_SNAPSHOT_CHUNK` handling
   and the download is capped at `MAX_SNAPSHOT_FILE_SIZE`.
2. **Single download per checkpoint.** Download state is keyed by
   checkpoint hash; chunks are pulled chunk-by-chunk with
   `getsnapshotdata` / `snapshotdata` and written to a `.temp` file in
   `<datadir>/snapshots/`, then renamed to the final
   `<height>-<blockhash>.dat` on completion.
3. **Sidecar.** The advertised `utxo_hash` is persisted alongside the
   snapshot as a `.hash` sidecar. `PopulateAndValidateSnapshot()`
   (`src/init.cpp:1605-1650`) validates the coin data of the loaded
   snapshot against this sidecar before the chainstate is activated.
4. **Lifecycle.** Completed or stalled download trackers are swept by a
   periodic sweep; peer sets are cleaned on disconnect. Hardening PRs
   #53–#55 (upstream) address the caps, rate limiting and tracker
   lifetime around this path; PR #52 cross-checks the metadata base hash
   against the snapshot filename.

## Consequences

- A fresh node skips the full block replay; the chain history it did not
  download is permanently unavailable (mandatory pruning), which is
  accepted by design ([ADR-0003](adr-0003-mandatory-prune-model.md)).
- The first snapshot source effectively determines the data a
  bootstrapping node validates against — see
  [ADR-0005](adr-0005-snapshot-source-selection.md) and
  [ADR-0006](adr-0006-sidecar-trust-model.md) for the open trust
  questions.

## Flow

```mermaid
sequenceDiagram
    participant S as Serving node (NODE_SNAPSHOT)
    participant N as Bootstrapping node
    participant I as PopulateAndValidateSnapshot (init.cpp)

    S->>N: UTXOSNAPSHOT advert (checkpoint hash, height, file size, utxo hash)
    N->>N: gate: target matches + IBD / invalid chain / behind prune horizon
    N->>S: getutxosnap (init download state)
    loop per chunk
        N->>S: getsnapshotdata
        S-->>N: snapshotdata (chunk)
    end
    N->>N: assemble in snapshots/&lt;height&gt;-&lt;hash&gt;.dat.temp, rename on completion
    N->>I: load snapshot + .hash sidecar
    I->>I: validate coin data against sidecar utxo_hash
    I-->>N: ok -> activate chainstate from snapshot
```