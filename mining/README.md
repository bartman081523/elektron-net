# Elektron Net Standalone Mining Software

This directory contains standalone CPU and GPU mining tools for Elektron Net, fully conforming to the standard Bitcoin mining protocol (`getblocktemplate` + `submitblock`).

## Files

| File | Description |
|------|-------------|
| `mine_genesis.py` | Python script to mine genesis blocks for all networks. |
| `generate_address.py` | Generate Elektron Net addresses (P2PKH + P2WPKH) with private keys. |
| `miner.py` | Standalone Python miner. Connects via RPC, fetches templates, mines, submits. |
| `miner.cpp` | Standalone C++ miner. Multi-threaded; builds coinbase from `coinbase_required_outputs` (UTXO attestation + witness). |
| `config.json` | Configuration file for all miners (RPC, payout address, threads). |
| `CMakeLists.txt` | Build file for the C++ miner (plus optional CUDA target). |
| `miner_cuda.cu` | Standalone CUDA miner (SHA-256d kernel, midstate + nTime rolling, joint CPU + GPU mining, solo + pool mode). |
| `build-cuda.sh` | Direct nvcc build script for `elektron_miner_cuda` (micromamba/conda toolchain). |

---

## Node Setup & RPC Configuration

Before any miner can connect, the Elektron Net node must be running with RPC enabled.

### Node Configuration

The node reads `bitcoin.conf` (the filename is still inherited from upstream Bitcoin Core).  
On **Windows** the file belongs in:

```
%LOCALAPPDATA%\Elektron\bitcoin.conf
```

(If the `Elektron` folder does not exist yet, create it manually.)

Minimal configuration for local solo-mining:

```ini
# Add Master Seed Node
addnode=seed.elektron-net.org:8333

# RPC-Server
server=1

# RPC (only local)
rpcuser=elek
rpcpassword=pass
rpcbind=127.0.0.1
rpcallowip=127.0.0.1

# Allow inbound P2P connections
listen=1
```

**Note:** The genesis block in the official repository is already finalized.
`src/kernel/chainparams.cpp` contains the real `assert(...)` values.
You only need to run `mine_genesis.py` if you are creating a completely new fork.

### Wallet Setup (Required for Mining)

The standalone miners need a **payout address**. Generate one first:

```bash
# Via the node's built-in wallet
./elektron-cli createwallet "miner"
./elektron-cli -rpcwallet=miner getnewaddress
# Result: e.g. "be1qccy42avfqnw2wxf8c790w3nqtj0vwtmmc0uz6y"
```

Alternatively, use the offline address generator:

```bash
python3 generate_address.py
```

Copy this address into `config.json` (field `mining.address`) or pass it via `--address`.

### Quick Mining via `generatetoaddress`

If you prefer the node's built-in mining over the standalone miners:

```bash
./elektron-cli createwallet "miner"
./elektron-cli -rpcwallet=miner getnewaddress
./elektron-cli -rpcwallet=miner generatetoaddress 1 "<address>"
```

---

## Mining Pools (Stratum / ASIC)

ASIC firmware does **not** need changes. **Pool backends** must include
`coinbase_required_outputs` from `getblocktemplate` in every coinbase
(witness commitment + per-block UTXO attestation).

Full integration guide: [`doc-elektron/mining-pool-integration.md`](../doc-elektron/mining-pool-integration.md)

---

## Protocol Compliance

Both miners use the **standard Bitcoin RPC mining protocol**:

1. `getblocktemplate` -- fetch work from the node.
2. SHA-256d brute-force on the block header.
3. `submitblock` -- send the solved block back to the node.

This is the same mechanism used by `cgminer`, `bfgminer`, and Bitcoin Core's internal `generate` (now `generatetoaddress`).

---

## Configuration File (`config.json`)

All settings can be placed in `config.json` in the same directory as the miner.

```json
{
  "rpc": {
    "url": "http://127.0.0.1:8332",
    "user": "elek",
    "password": "pass"
  },
  "mining": {
    "address": "be1qccy42avfqnw2wxf8c790w3nqtj0vwtmmc0uz6y",
    "threads": 4,
    "continuous": true,
    "target_spacing": 60
  },
  "pool": {
    "enabled": false,
    "url": "stratum+tcp://pool.elektron-net.org:3333",
    "user": "worker.1",
    "password": "x"
  }
}
```

### Config Reference

| Section | Key | Type | Default | Description |
|---------|-----|------|---------|-------------|
| `rpc` | `url` | string | `http://127.0.0.1:8332` | RPC endpoint of the Elektron Net node. |
| `rpc` | `user` | string | `"user"` | RPC username. |
| `rpc` | `password` | string | `"password"` | RPC password. |
| `mining` | `address` | string | `""` | **Payout address** (bech32 or base58). **Required.** |
| `mining` | `threads` | integer | `4` | Number of CPU threads for mining. |
| `mining` | `continuous` | boolean | `false` | Mine continuously in a loop. |
| `mining` | `target_spacing` | integer | `60` | Block target spacing in seconds (informational only). |
| `pool` | `enabled` | boolean | `false` | Enable Stratum pool mining (C++ miner only). |
| `pool` | `url` | string | `"stratum+tcp://..."` | Stratum pool URL. |
| `pool` | `user` | string | `"worker.1"` | Pool worker username. |
| `pool` | `password` | string | `"x"` | Pool worker password. |

---

## Python Miner (`miner.py`)

### Requirements

- Python 3.8+
- No external dependencies (stdlib only)

### Command-Line Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--url` | from `config.json` or `http://127.0.0.1:8332` | RPC endpoint URL. Overrides config. |
| `--user` | from `config.json` or `"user"` | RPC username. Overrides config. |
| `--password` | from `config.json` or `"password"` | RPC password. Overrides config. |
| `--address` | from `config.json` or `""` | **Payout address** (bech32 or base58). Overrides config. |
| `--threads` | from `config.json` or `4` | Number of mining threads. Overrides config. |
| `--continuous` | from `config.json` or `false` | Mine continuously in a loop (non-stop). Overrides config. |

### Usage Examples

```bash
# Minimal: read everything from config.json
python3 miner.py

# Specify payout address directly (overrides config.json)
python3 miner.py --address be1qccy42avfqnw2wxf8c790w3nqtj0vwtmmc0uz6y

# Custom RPC credentials + address + continuous mining
python3 miner.py --url http://127.0.0.1:8332 --user elek --password secret \
                 --address be1qccy42avfqnw2wxf8c790w3nqtj0vwtmmc0uz6y \
                 --threads 8 --continuous
```

### Supported Address Formats

The Python miner automatically detects and supports:

- **Bech32 (native SegWit):** `be1q...` (P2WPKH, v0), `be1p...` (P2TR, v1)
- **Base58 (legacy):** `1...` (P2PKH mainnet), `3...` (P2SH mainnet)
- **Base58 (testnet/regtest):** `m...` / `n...` (P2PKH), `2...` (P2SH)

---

## C++ Miner (`miner.cpp`)

### Requirements

- C++20 compiler (GCC 10+, Clang 12+, MSVC 2019+)
- CMake 3.16+
- libcurl
- OpenSSL

## For build with dynamic DLL
### Select folder
```
cd C:\Users\<username>\Desktop\Elektron\mining
```

### Dependencies (if not installed)
```
& "C:\Program Files\Microsoft Visual Studio\18\Community\VC\vcpkg\vcpkg.exe" install --triplet x64-windows
```

### Build-Folder
```
rm -Recurse -Force build -ErrorAction SilentlyContinue
mkdir build
cd build
```

### CMake
```
cmake .. `
  -DCMAKE_TOOLCHAIN_FILE="C:\Program Files\Microsoft Visual Studio\18\Community\VC\vcpkg\scripts\buildsystems\vcpkg.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows `
  -DCMAKE_BUILD_TYPE=Release
```

### Build
```
cmake --build . --config Release
```

## For build with static exe
### Select folder
```
cd C:\Users\<username>\Desktop\Elektron\mining
```

### Dependencies (if not installed)
```
& "C:\Program Files\Microsoft Visual Studio\18\Community\VC\vcpkg\vcpkg.exe" install --triplet x64-windows-static
```

### Build-Folder
```
rm -Recurse -Force build -ErrorAction SilentlyContinue
mkdir build
cd build
```

### CMake
```
cmake .. `
  -DCMAKE_TOOLCHAIN_FILE="C:\Program Files\Microsoft Visual Studio\18\Community\VC\vcpkg\scripts\buildsystems\vcpkg.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows-static `
  -DCMAKE_BUILD_TYPE=Release
```

### Build
```
cmake --build . --config Release
```

### Usage

```bash
# Default: reads config.json in same directory
./elektron_miner

# Custom config path
./elektron_miner /path/to/config.json
```

---

## CUDA GPU Miner (`miner_cuda.cu`)

NVIDIA GPU + CPU solo/pool miner. Same protocol layer as the C++ miner
(`getblocktemplate` → coinbase → merkle → header → `submitblock`), with three
efficiency layers:

- **Midstate optimization** — the first SHA-256 block (version, prev-hash,
  merkle prefix) is compressed once per job on the host; only the second
  block is hashed per nonce (GPU kernel and CPU workers alike).
- **nTime rolling** — a full 2^32 nonce sweep takes ~2.5 s, but a template
  stays valid ~60 s. When a refetched template is byte-identical to the
  current job except for its nTime, the miner rolls nTime forward by 1 s
  (bounded by the template's `maxtime`) instead of re-scanning the identical
  header — without rolling, ~96% of all hashes were duplicates.
- **CPU + GPU joint mining** — the nonce space is partitioned: the GPU scans
  chunks `[0, 256 − cpu_threads)`, CPU worker *i* owns chunk `256 − cpu_threads + i`
  (one chunk = 2^24 nonces). CPU workers hash via OpenSSL's
  `SHA256_Transform` midstate path (uses SHA-NI on modern x86) and roll their
  own nTime independently. Each find is re-verified on the CPU before it is
  submitted.

### Requirements

- NVIDIA GPU, compute capability ≥ 5.0 (Maxwell+). Default build targets sm_75 (Turing).
- CUDA toolkit (nvcc 12.x works). Either via micromamba/conda or the system toolkit.
- libcurl + OpenSSL (host-side protocol layer links the same libs as the C++ miner).

### Build

**Option A — build script (recommended, uses the `elektron-cuda` micromamba env):**

```bash
cd mining

# One-time: create the CUDA toolkit environment
micromamba create -n elektron-cuda -c nvidia -c conda-forge \
    cuda-nvcc cuda-cudart-dev cuda-cudart libcurl openssl cuda-version=12.9

# Build (writes elektron_miner_cuda next to the script or into the given dir)
./build-cuda.sh ../build/bin
```

The GPU architecture can be overridden with `ELEK_CUDA_ARCH` (e.g.
`ELEK_CUDA_ARCH=86` for Ampere). The script links the conda env's libcurl/
OpenSSL and embeds an rpath, so the binary runs without LD_LIBRARY_PATH tweaks.

**Option B — CMake (uses the system CUDA toolkit):**

```bash
export CUDACXX=$HOME/micromamba/envs/elektron-cuda/bin/nvcc   # or system nvcc
cmake -B build -DELEKTRON_BUILD_CUDA_MINER=ON -DCMAKE_CUDA_ARCHITECTURES=75
cmake --build build
```

`ELEKTRON_BUILD_CUDA_MINER` is OFF by default; without a usable CUDA compiler
CMake fails with a pointer to CUDACXX / `build-cuda.sh`.

### Selftest

The binary runs a 7-part selftest on every start (before any mining) and
refuses to mine if it fails:

1. **SHA-256d correctness** — 4096 random 80-byte headers, GPU digest vs OpenSSL, must be identical.
2. **Known-nonce scan** — a nonce whose digest beats a full-size target must be found inside its scan window and is re-verified on the CPU.
3. **Difficulty → target conversion** — diff 1 / 0.001 / 65536 map to 2^224 / 2^233 / 2^208.
4. **Benchmark** — measures the raw GPU hashrate over a 3 s sweep.
5. **CPU midstate path** — 512 digests via `SHA256_Transform` vs plain `sha256d`.
6. **CPU thread benchmark** — single-thread midstate-path hashrate (MH/s).
7. **CPU worker pool** — a `CpuPool` scan must find a qualifying nonce against a tightened target, re-verify it independently and report it via `poll_find()`.

```bash
./elektron_miner_cuda config.json --selftest     # selftest only, exit afterwards
./elektron_miner_cuda config.json --noselftest   # skip selftest, start mining directly
```

### Config

Reads the same `config.json` as the C++ miner. `mining.threads` sets the
number of **CPU workers** (default 4); the GPU grid is auto-sized from the
device (34 SMs × 1024 threads/SM on an RTX 2060). Optional extras:

```json
{
  "rpc": {
    "url": "http://127.0.0.1:8332",
    "user": "elek",
    "password": "pass"
  },
  "mining": {
    "address": "be1qz6g54krxvqtyuzkh340qdm57wukckzejayvp63",
    "threads": 4,
    "continuous": true
  },
  "cpu":  { "threads": 4 },
  "cuda": { "device": 0 }
}
```

| Section | Key | Meaning |
|---------|-----|---------|
| `mining` | `threads` | CPU worker count (used only if `cpu.threads` is absent). |
| `cpu` | `threads` | Explicit CPU worker count; `-1` = follow `mining.threads`, `0` = GPU only. Capped by the machine's core count. |
| `cuda` | `device` | CUDA device ordinal. |

The env var `ELEK_CUDA_TPB` (64–1024, multiple of 32) overrides the kernel's
threads-per-block for benchmarking; the default 256 measured fastest on
Turing.

`ELEK_CUDA_ILP` (1, 2 or 4) selects how many consecutive nonces each thread
hashes in interleaved SHA-256 chains (multi-candidate ILP, the hashcat /
cpuminer-multi trick). Measured on an RTX 2060 (sm_75) it always loses:
with 64k registers per SM every variant keeps exactly 1024 concurrent
chains resident, so ILP only trades warp-scheduler latency hiding for
register pressure — best cells were 1.41 GH/s (ILP=2) and 1.30 GH/s
(ILP=4) vs 1.72 GH/s (ILP=1). The default stays 1; the knob exists for
GPUs with a different register/SM balance. ILP×block-size combinations
that exceed the SM register file are rejected at startup and fall back to
ILP=1 instead of failing the first launch.

### Usage

```bash
# Solo mining against the local node (default) -- GPU + CPU workers
./elektron_miner_cuda config.json

# Pool mining via stratum
./elektron_miner_cuda config.json   # with pool.enabled = true
```

CPU workers are active in **solo mode only** — in pool mode the GPU scans
the full nonce space, exactly like before.

### systemd (user unit, Linux)

```ini
# ~/.config/systemd/user/elektron-miner-cuda.service
[Unit]
Description=Elektron Net GPU Miner (CUDA)
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/stdbuf -oL /opt/elektron/bin/elektron_miner_cuda /opt/elektron/bin/config.json
Restart=on-failure
RestartSec=5
Nice=5

[Install]
WantedBy=default.target
```

(`stdbuf -oL` is needed because the miner's stdout is fully buffered when
piped to journald, otherwise the log stays empty for minutes.)

```bash
systemctl --user daemon-reload
systemctl --user enable --now elektron-miner-cuda.service
journalctl --user -u elektron-miner-cuda.service -f
```

### Throughput

Measured on an RTX 2060 12GB (Turing, sm_75) + Ryzen 5 5600X (4 CPU workers)
at the current mainnet difficulty (~115 700):

- **~1.75 GH/s combined** — GPU ~1.69 GH/s (256 chunks × 16.7 M nonces
  ≈ 4.29 G nonces per ~2.5 s sweep) + CPU ~0.06 GH/s (4 × ~15 MH/s, SHA-NI)
- Before nTime rolling, every sweep re-hashed the identical header
  (~96% duplicates); with rolling each sweep hashes fresh work, so the
  *effective* hashrate rose by the same factor.
- Mean time to a block at difficulty 1 ≈ 2.5 s; at current mainnet
  difficulty (~115 700) ≈ 3.4 days per 5 ELEK block. Expect long dry
  spells — the variance of solo mining is huge.

---

## Address Generator

Generate wallet addresses with full credentials (private key, WIF, public key, P2PKH, P2WPKH).

```bash
# Generate one random address
python3 generate_address.py

# Generate 5 addresses for a mining farm
python3 generate_address.py --count 5 --output my_farm.txt

# Deterministic generation from a seed
python3 generate_address.py --seed 95402f1dffe959ef95c0c403341e610e85d31bb7adf06ff7fe29ea6e142c30f7
```

Output is written to a `.txt` file containing all keys. **Keep it secure.**

---

## Genesis Mining

**Do NOT run `mine_genesis.py` until you are ready to finalize the chain parameters.**

When the time comes:

```bash
cd mining
python3 mine_genesis.py
```

This will output nonces, block hashes, and merkle roots for Mainnet, Testnet3, Testnet4, Signet, and Regtest. Copy these values into `src/kernel/chainparams.cpp`.

The script also writes `genesis_results.txt` (contains the genesis private key -- **never commit this file**).
