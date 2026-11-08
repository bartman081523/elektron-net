#!/usr/bin/env bash
# Build the Elektron Net CUDA miner (elektron_miner_cuda).
#
# Compiler strategy:
#   1. system nvcc, if a CUDA toolkit is installed (links against the system
#      libcurl/OpenSSL)
#   2. otherwise: micromamba is bootstrapped (if not present) and the CUDA
#      toolkit environment "elektron-cuda" is created automatically
#      (nvcc 12.9 + conda-forge gcc 13 as host compiler + libcurl/OpenSSL)
#
# Environment:
#   ELEK_CUDA_ARCH              GPU arch (default 75 = RTX 2060)
#   ELEK_CUDA_FORCE_MICROMAMBA  =1: skip a system nvcc, use the micromamba env
#   ELEK_CUDA_ENV               alternative micromamba env directory
#   ELEK_MAMBA_ROOT             alternative micromamba root prefix
#
# Usage:
#   ./build-cuda.sh [output_dir]
#
# Windows equivalent: build-cuda.bat
set -euo pipefail

ARCH="${ELEK_CUDA_ARCH:-75}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$SRC_DIR}"
mkdir -p "$OUT_DIR"

log() { echo "$*" >&2; }

# nvcc flags shared by both routes (word-split correctly via the array)
NVCC_FLAGS=(-O3 -std=c++20 -arch=sm_"$ARCH" -Xptxas -v)

# ---------------------------------------------------------------------------
# 1. System CUDA toolkit
# ---------------------------------------------------------------------------
FORCE_MM="${ELEK_CUDA_FORCE_MICROMAMBA:-0}"
SYSTEM_NVCC="$(command -v nvcc || true)"

if [[ "$FORCE_MM" != 1 && -n "$SYSTEM_NVCC" ]]; then
    log "using system nvcc: $SYSTEM_NVCC"
    rc=0
    "$SYSTEM_NVCC" "${NVCC_FLAGS[@]}" \
        "$SRC_DIR/miner_cuda.cu" \
        -o "$OUT_DIR/elektron_miner_cuda" \
        -lcurl -lssl -lcrypto -lpthread || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "built: $OUT_DIR/elektron_miner_cuda"
        exit 0
    fi
    log "system nvcc build failed (rc=$rc) -- are the libcurl/openssl development"
    log "packages installed (e.g. libcurl4-openssl-dev libssl-dev)?"
    log "or force the self-contained route: ELEK_CUDA_FORCE_MICROMAMBA=1 $0"
    exit "$rc"
fi

# ---------------------------------------------------------------------------
# 2. Micromamba CUDA environment (bootstrapped on demand)
# ---------------------------------------------------------------------------
MAMBA_ROOT="${ELEK_MAMBA_ROOT:-$HOME/micromamba}"
export MAMBA_ROOT_PREFIX="$MAMBA_ROOT"
MICROMAMBA="$MAMBA_ROOT/bin/micromamba"
ENV_DIR="${ELEK_CUDA_ENV:-$MAMBA_ROOT/envs/elektron-cuda}"

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)          MAMBA_ARCH=linux-64 ;;
    Linux-aarch64|Linux-arm64) MAMBA_ARCH=linux-aarch64 ;;
    Darwin-*) log "error: CUDA is not available on macOS"; exit 1 ;;
    *) log "error: unsupported platform $(uname -s)-$(uname -m)"; exit 1 ;;
esac

if [[ ! -x "$MICROMAMBA" ]]; then
    log "bootstrapping micromamba into $MAMBA_ROOT ..."
    command -v curl >/dev/null || { log "error: curl is required"; exit 1; }
    mkdir -p "$MAMBA_ROOT"
    curl -Ls "https://micro.mamba.pm/api/micromamba/$MAMBA_ARCH/latest" \
        | tar -xj -C "$MAMBA_ROOT" bin/micromamba
fi

if [[ ! -x "$ENV_DIR/bin/nvcc" ]]; then
    log "creating CUDA build env 'elektron-cuda' in $ENV_DIR ..."
    log "(nvcc 12.9 + conda-forge gcc 13 host compiler + libcurl + openssl)"
    "$MICROMAMBA" create -y \
        -n elektron-cuda \
        -c nvidia -c conda-forge \
        cuda-nvcc cuda-cudart-dev cuda-cudart cuda-cudart-static \
        libcurl openssl \
        "cuda-version=12.9"
fi

NVCC="$ENV_DIR/bin/nvcc"
HOSTCC="$(ls "$ENV_DIR"/bin/*-conda-*g++ 2>/dev/null | head -1 || true)"
HOSTCC="${HOSTCC:-g++}"
log "using env nvcc: $NVCC (host compiler: $HOSTCC)"

"$NVCC" \
    -ccbin "$HOSTCC" \
    "${NVCC_FLAGS[@]}" \
    -I "$ENV_DIR/include" \
    -L "$ENV_DIR/lib" \
    -Xlinker -rpath -Xlinker "$ENV_DIR/lib" \
    "$SRC_DIR/miner_cuda.cu" \
    -o "$OUT_DIR/elektron_miner_cuda" \
    -lcurl -lssl -lcrypto -lpthread

echo "built: $OUT_DIR/elektron_miner_cuda"