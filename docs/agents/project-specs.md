# Project Specs — Elektron Net

> Single source of truth for project-specific facts. Loaded by the
> orchestrator in [`../../AGENTS.md`](../../AGENTS.md). Every claim below
> carries a source (`file:line`, executed command, or doc reference).
> Claims that could not be verified in this session are marked
> `UNVERIFIED` with their doc source.

## Overview

Elektron Net is a **minimal Bitcoin Core fork** (v4.0.5,
`CMakeLists.txt:29-38`) that keeps upstream consensus, emission and
network architecture and adds a small, deliberate feature set:

1. **60-second block time** (`nPowTargetSpacing = 60`,
   `src/kernel/chainparams.cpp:95`).
2. **Mandatory 137-day pruning** (`MANDATORY_PRUNE_DEPTH = 197280`,
   `src/validation.h:84`; the `-prune=<GB>` option is silently ignored —
   `src/node/blockmanager_args.cpp:38-40` casts `nPruneTarget` away).
3. **Per-block UTXO attestation**: every block with `height > 0` must carry
   a 37-byte coinbase `OP_RETURN` payload `height(4B) + UTXO-set MuHash
   (32B)` (`src/node/miner.cpp:217-218`); consensus enforces it in
   `ValidateUTXOCheckpoint` (`src/validation.cpp:2509-2549`, genesis-only
   skip at `:2512-2513`, call site in `ConnectBlock` at `:3069`).
4. **Automatic UTXO snapshots**: the node periodically writes
   `<datadir>/snapshots/<height>-<blockhash>.dat` plus a `.hash` sidecar
   (`src/validation.cpp:2555-2682`), advertises `NODE_SNAPSHOT`
   (`init.cpp:1434`), and serves/downloads snapshots over the P2P wire
   (`getutxosnap` / `utxosnapshot` / `getsnapdata` / `snapshotdata`,
   `src/protocol.h:278-294`) so fresh nodes bootstrap from a snapshot
   instead of replaying 137 days of blocks.

Everything else — script engine, PoW (SHA-256d), wallet, P2P layer — is
inherited from Bitcoin Core. Fork changes are catalogued file-by-file in
`doc-elektron/BITCOIN_CORE_DIFF.md`.

### Network parameters (mainnet)

| Parameter | Value | Source |
|---|---|---|
| Message magic | `0xe1ec7a6e` | `chainparams.cpp:176-179` |
| HRP | `be` (→ `be1q…`/`be1p…`) | `chainparams.cpp:222` |
| P2P / RPC port | 8333 / 8332 | `TECHNICAL_SETUP.md:565-573` |
| SLIP-44 coin type | 1370 (`ELEK`) | guide (verified vs. code) |
| Protocol version | 70017 | guide (verified vs. code) |
| Genesis | `CreateGenesisBlock(1781164284, 8892291, 0x1d7fffff, 1, 5*COIN)` | `chainparams.cpp:185` |
| Halving interval | 2102400 blocks (~4 a) | `chainparams.cpp:85` |
| BIP34/65/66/CSV/SegWit heights | all `1` | `chainparams.cpp:86-91` |
| MuhashAttestationActivationHeight | 137000 | `chainparams.cpp:117/126/157` |
| StoicAwakeningEndHeight | 150000 | `chainparams.cpp:117/126/157` |
| IntraBlockAttestationFixActivationHeight | 170000 | `chainparams.cpp:117/126/157` |
| MandatoryPruneDepth | 197280 blocks (~137 d) | `chainparams.cpp:158` |
| MIN_BLOCKS_TO_KEEP | 2880 | `src/validation.h:77` |
| DNS seed | `seed.elektron-net.org` | `chainparams.cpp:195-211` |

## Build Commands

```bash
# Configure (out-of-source mandatory — CMakeLists.txt:17 forbids in-source)
cmake -B build

# Build (verified — executed repeatedly in the working build tree)
cmake --build build -j"$(nproc)"
```

<!-- verified: `cmake --build build -j"$(nproc)"` executed repeatedly
     (configure was performed once when the build tree was created). -->

- Presets (`cmake --list-presets`, verified): `libfuzzer`, `libfuzzer-nosan`,
  `dev-mode` on Linux. The `vs2026` / `vs2026-static` presets are
  Windows-conditioned (`CMakePresets.json`).
- `dev-mode` preset builds into `build_dev_mode/` with every feature ON
  (`CMakePresets.json`).
- Produced binaries: `elektrond`, `elektron-cli`, `elektron-tx`,
  `elektron-wallet`, `elektron-qt` (upstream names renamed via
  `CMakeLists.txt:634-677`).
- Notable CMake options and defaults (`CMakeLists.txt:96-190`):
  `BUILD_GUI=OFF`, `WITH_ZMQ=OFF`, `WITH_USDT=OFF`, `BUILD_TESTS=ON`,
  `ENABLE_WALLET=ON`, `WITH_CCACHE=ON`, `ENABLE_IPC=ON`.
- Only `test/`, `doc/`, `src/` are wired via `add_subdirectory`
  (`CMakeLists.txt:620-623`); `mining/` is a standalone build, **not**
  part of the node build.
- **Repository state caveat**: a working out-of-source build tree exists
  at `build/` (binaries under `build/bin/`). `build_dev_mode/` still
  contains an aborted configure (target system misdetected as GHS-MULTI,
  0 ctest tests registered). The stray in-tree
  `CMakeCache.txt`/`CMakeFiles/` noted earlier have been removed.
- The CUDA miner is **not on `main`** — it lives on the separate
  `cuda-miner` branch (`mining/build-cuda.sh`, `mining/build-cuda.bat`,
  `mining/miner_cuda.cu`; `ELEK_CUDA_ARCH` defaults to 75 =
  Turing/RTX 2060). Not hooked into CMake.

## Specifications & references

Normative landscape for this repo (all under the repo unless noted):

- **`doc-elektron/ELEKTRON_NET_AI_AGENT_GUIDE.md`** — the fork's own
  "source map for independent code review": locator, not verdict. Review
  method at `:101-111`, finding format at `:480-482`
  (`[severity] claim — evidence: path:symbol — observation: … — residual
  risk: …`), 22-item review checklist at `:438-478`, maintainer-sync note
  `:505`.
- **`doc-elektron/BITCOIN_CORE_DIFF.md`** — file-by-file diff vs upstream
  Bitcoin Core with provenance markers (● fork-owned, ○ upstream,
  ＋ added).
- **`doc-elektron/DESIGN_RATIONALE.md`**, **`doc-elektron/mining-pool-integration.md`**
  (GBT/Stratum contract), **`WHITEPAPER.md`**,
  **`TECHNICAL_SETUP.md`** (genesis → build → node → mining → DNS seed),
  **`right-to-be-forgotten.md`** (repo root, outside `doc/`).
- **Upstream Bitcoin Core docs** (`doc/`, `CONTRIBUTING.md`) remain
  authoritative for inherited behaviour.
- Comparison implementation: upstream Bitcoin Core at the same version
  lineage (4.0.x).

**Known documentation ↔ code drift** — re-verify against code before
trusting these docs:

| # | Doc claim | Actual code |
|---|---|---|
| D1 | `DESIGN_RATIONALE.md:186` cites `validation.cpp:2920` for the attestation gate | actual `validation.cpp:2509` |
| D2 | `DESIGN_RATIONALE.md:187` cites `:2439` | actual `:2555` (`WriteAutomaticSnapshot`) |
| D3 | `DESIGN_RATIONALE.md:70` cites `validation.h:79` | actual `:84` (`MANDATORY_PRUNE_DEPTH`) |
| D4 | `BITCOIN_CORE_DIFF.md` §3.1: UTXO-MuHash CoinsDB key `'U'` | actual `'V'` (`src/txdb.cpp:35`) |
| D5 | `BITCOIN_CORE_DIFF.md`: wire names `getutxosnapshot` / `getsnapshotdata` | actual `getutxosnap` / `getsnapdata` (`src/protocol.h:278,289`) |
| D6 | CUDA miner documented in `mining/README.md` | absent from `main` (no CUDA code, no README section); lives only on the `cuda-miner` branch |

## Linting / Formatting

- Rust lint runner: `test/lint/test_runner` (17 registered checks,
  `test/lint/test_runner/src/main.rs:36-118`). **UNVERIFIED** — needs a
  cargo build; not executed in this session.
- 14 standalone Python linters in `test/lint/lint-*.py` (wired into the
  Rust runner via `all_python_linters`).
- Formatting: upstream Core toolchain — `clang-format` +
  `test/lint/check-clang-format.py`, `.editorconfig`, `.style.yapf` for
  Python.
- `ci/lint.py` runs the full lint suite **inside a container**
  (`ci/README.md:57`) — Docker is not permitted in this environment; use
  the runner scripts above directly.

## Coding Conventions

Inherited Bitcoin Core style (sampled across
`src/node/miner.cpp`, `src/wallet/wallet.cpp`, `src/kernel/chainparams.cpp`,
`src/consensus/tx_verify.cpp`, `test/functional/test_framework/blocktools.py`):

- `clang-format`-governed C++; spaces, never tabs; `.editorconfig` sets
  the baseline.
- IWYU pragmas (`// IWYU pragma: …`) in headers where upstream uses them.
- Upstream naming: `CamelCase` types/functions, `snake_case` locals,
  `ALL_CAPS` constants; fork code matches upstream style (no style break
  observed in sampled files).
- Fork-specific code comments often carry an "Elektron Net:" marker
  (e.g. `src/node/blockmanager_args.cpp:38`) — useful for locating
  fork-owned logic.

## Commit Message Style

From recent `git log` on this clone:

- Subject: `<area>: <summary>` prefixes (`wallet:`, `validation:`,
  `mining:`, `doc:` …).
- Body pattern observed: **Consequences: / Observed live: / Fix: /
  New test** sections describing root cause and verification.
- Trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`.
- **Repo-local git identity is `BuildBot <build@example.com>`** — set in
  this clone's `.git/config`; check before committing.

## Common Workflows

1. **Fresh build**: `cmake -B build && cmake --build build -j$(nproc)`
   (UNVERIFIED, see above caveat about stray build artefacts).
2. **Unit tests**: `ctest --test-dir build` — ctest names equal the Boost
   suite names (`src/test/CMakeLists.txt:180-206`).
3. **Single functional test**: must run **from the build dir** —
   `build/test/functional/test_runner.py feature_rbf.py`. The runner
   requires a CMake-generated `config.ini` (`test/CMakeLists.txt:36`);
   running `python3 test/functional/test_runner.py` from the source tree
   fails with `FileNotFoundError: …/test/functional/../config.ini`
   (verified in this session).
4. **Regenerate seed lists**: edit `contrib/seeds/generate-seeds.py`
   output is pasted into `src/chainparamsseeds.h` (see "Generated
   artefacts").
5. **Fork doc updates**: a change to attestation/pruning/snapshot behaviour
   updates the matching `doc-elektron/*.md` in the same PR (see D1–D6 for
   why stale docs are a live problem here).
6. **Review a consensus-adjacent change**: use the
   `doc-elektron/ELEKTRON_NET_AI_AGENT_GUIDE.md` review method (`:101-111`)
   and finding format (`:480-482`).
7. **Local mining**: see `mining/README.md` (Python miner + config.json;
   CUDA miner only on the `cuda-miner` branch via `mining/build-cuda.sh`).

## Architecture Overview

Data flow of the fork-specific path:

1. **P2P → validation**: peers deliver blocks through the unchanged
   upstream pipeline (`net_processing.cpp` → `ProcessNewBlock`).
2. **Block connection**: `ConnectBlock` invokes
   `ValidateUTXOCheckpoint` (`src/validation.cpp:3069` → `:2509-2549`);
   the gate is skipped only for genesis. Rejections surface as
   `missing-utxo-attestation` / `bad-utxo-attestation(-compute)`.
3. **Commitment bookkeeping**: the UTXO-set MuHash is maintained
   incrementally in `UTXOMuHashState`; persisted under CoinsDB key `'V'`
   (`src/txdb.cpp:35`). `ComputeBlockUTXOAttestationHash`
   (`validation.cpp:2378`) and `ExtractCoinbaseUTXOAttestation`
   (`:2438`) produce/parse the 37-byte payload; the miner assembles it in
   `src/node/miner.cpp:204-226`.
4. **Mandatory pruning**: `MANDATORY_PRUNE_DEPTH` (197280) is enforced
   structurally; user `-prune` is discarded
   (`src/node/blockmanager_args.cpp:38-40`), `MIN_BLOCKS_TO_KEEP=2880`
   bounds how long recent blocks stay (`src/validation.h:77`).
5. **Automatic snapshots**: `WriteAutomaticSnapshot`
   (`src/validation.cpp:2555`) writes
   `<datadir>/snapshots/<height>-<blockhash>.dat` + `.hash` sidecar
   (`:2564-2682`); the node advertises `NODE_SNAPSHOT`
   (`init.cpp:1434`) and serves peers via
   `getutxosnap`/`getsnapdata` (`src/protocol.h:278-294`); fresh nodes
   bootstrap from the latest snapshot instead of replaying pruned history.

Key files:

| File | Fork role |
|---|---|
| `src/kernel/chainparams.cpp` | all network parameters + activation heights |
| `src/validation.cpp` / `src/validation.h` | attestation gate, MuHash state, snapshot writer, prune constants |
| `src/node/miner.cpp` | coinbase attestation assembly |
| `src/txdb.cpp` | CoinsDB `'V'` key for UTXO MuHash |
| `src/protocol.h` | new wire message types |
| `src/net_processing.cpp` | snapshot serving/download |
| `src/init.cpp` | `NODE_SNAPSHOT` advertisement, lifecycle wiring |
| `src/node/blockmanager_args.cpp` | mandatory-prune override |
| `mining/` | standalone CPU/Python/CUDA miners (own build) |

Pool contract (from `doc-elektron/mining-pool-integration.md`, verified
against `src/node/miner.cpp`): `getblocktemplate` requires
`coinbaseaddress`, pools must emit `coinbase_required_outputs` verbatim
(witness commitment + attestation `OP_RETURN`), coinbase `nLockTime`
is `height - 1` (`mining-pool-integration.md:137`).

## Testing

- **Unit**: Boost-based; ctest target names equal suite names
  (`src/test/CMakeLists.txt:180-206`).
- **Functional**: Python tests are **not** ctest-registered; they require
  the CMake-generated `config.ini`, so run from the build dir
  (verified failure from the source tree, see Common Workflows #3).
  Full suite: `build/test/functional/test_runner.py`; single test:
  `build/test/functional/test_runner.py <feature_x.py>`.
- **Fuzz**: `libfuzzer` / `libfuzzer-nosan` presets (`BUILD_FOR_FUZZING`).
- **Lint**: see Linting section.

## CI

- The only workflow is `.github/workflows/build.yaml`: Windows NSIS
  installer built on tags `v*` (ubuntu-24.04 runner, mingw + `depends/`).
  No CI test or lint jobs.
- `ci/` contains the upstream Core CI framework, which is
  **container-based** (`ci/README.md:57`) and therefore not usable in
  Docker-forbidden environments. Native alternative: configure + build +
  `ctest` directly, plus the Rust lint runner.

## Runtime Configuration

- **Config-file gotcha**: binaries are renamed but the config file is
  still `bitcoin.conf` and the default datadir still `Bitcoin`
  (`TECHNICAL_SETUP.md:400-406`).
- Mandatory pruning is automatic after 197280 blocks; `-prune=…` is
  accepted but ignored (`src/node/blockmanager_args.cpp:38-40`).
- Snapshot files live in `<datadir>/snapshots/`; nodes advertise and
  fetch them automatically (see Architecture Overview).
- Ports and network tables: `TECHNICAL_SETUP.md:565-573`; genesis
  parameters in `src/kernel/chainparams.cpp:176-211`.

## Dependencies

- `vcpkg.json` (manifest) and `depends/` for cross-builds; system
  dependencies per `doc/build-unix.md` (identical to upstream Core).
- The libbitcoin stack built by the workspace-level `build_all.sh`
  (secp256k1, libbitcoin-system, libbitcoin-explorer) is **not** part of
  the node build — it is a sibling toolchain in the parent directory,
  outside this repo.

## Source Layout

Upstream Bitcoin Core `src/` layout (unchanged directory structure) plus
fork additions at the repo root:

- `doc-elektron/` — fork-specific documentation (23 files).
- `mining/` — genesis tooling + CPU/Python miners (standalone CMake; the
  CUDA miner lives on the `cuda-miner` branch).
- `terminals/` — captured build logs.
- `build_dev_mode/` — preset build dir (currently an aborted configure).
- CMake entry points: root `CMakeLists.txt` → `test/`, `doc/`, `src/`
  only (`CMakeLists.txt:620-623`).

## Generated artefacts

- `src/chainparamsseeds.h` ← `contrib/seeds/generate-seeds.py` (output is
  pasted in; `contrib/seeds/generate-seeds.py` notes this at `:29`).
- `test/functional/config.ini` ← generated by CMake
  (`test/CMakeLists.txt:36`); required by the functional runner.
- `mining/genesis_results.txt` ← `mining/mine_genesis.py`. Its header
  warns `WALLET CREDENTIALS — DO NOT SHARE`. **CORRECTION (2026-09-22):**
  the *committed* copy was generated in no-wallet mode and contains no
  key material (`<not shown in no-wallet mode>`) — the earlier claim
  "contains a private key" was wrong. A wallet-mode regeneration would
  embed live WIF/hex keys, so the file must still stay untracked.

## Writing PRs

- `CONTRIBUTING.md` is stock upstream Bitcoin Core (zero fork-specific
  content) — general process rules apply, fork specifics are not
  documented there.
- No `.github/ISSUE_TEMPLATE/` exists; only `workflows/`.
- Commit style: see "Commit Message Style" above (observed from git log,
  not invented).
- For review artefacts, follow the guide's finding format
  (`doc-elektron/ELEKTRON_NET_AI_AGENT_GUIDE.md:480-482`).

## Verification Log

| # | Item | Status |
|---|---|---|
| 1 | `cmake --list-presets` → `libfuzzer`, `libfuzzer-nosan`, `dev-mode` | verified |
| 2 | `ctest -N` in `build_dev_mode` → 0 tests (aborted configure, GHS-MULTI misdetection) | verified |
| 3 | `python3 test/functional/test_runner.py --help` from source tree → `FileNotFoundError: config.ini` | verified |
| 4 | `cmake -B build` + `cmake --build build -j"$(nproc)"` | verified — build executed repeatedly; configure performed once when the build tree was created |
| 5 | `ctest --test-dir build` in a fresh build tree | UNVERIFIED — source: `doc/build-unix.md` |
| 6 | Rust lint runner (`test/lint/test_runner`, cargo run) | UNVERIFIED — source: `test/lint/README.md` |
| 7 | `mining/build-cuda.sh` | UNVERIFIED — script only exists on the `cuda-miner` branch, not on `main` |
| 8 | functional test suite from build dir | UNVERIFIED — source: `test/README.md:64-80` |
| 9 | `mining/miner.py` RPC loop | UNVERIFIED — source: `mining/README.md` |