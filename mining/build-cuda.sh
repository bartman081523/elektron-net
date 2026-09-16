#!/usr/bin/env bash
# Build the Elektron Net CUDA miner (elektron_miner_cuda).
#
# Uses the micromamba CUDA toolkit environment "elektron-cuda"
# (nvcc 12.9 + conda-forge gcc 13 as host compiler + libcurl/OpenSSL).
#
# Usage:
#   ./build-cuda.sh [output_dir]
#
# The GPU target (RTX 2060 = sm_75) can be overridden:
#   ELEK_CUDA_ARCH=86 ./build-cuda.sh
set -euo pipefail

ENV_DIR="${ELEK_CUDA_ENV:-$HOME/micromamba/envs/elektron-cuda}"
NVCC="$ENV_DIR/bin/nvcc"
HOSTCC="$ENV_DIR/bin/x86_64-conda-linux-gnu-g++"
ARCH="${ELEK_CUDA_ARCH:-75}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$SRC_DIR}"

if [[ ! -x "$NVCC" ]]; then
    echo "error: nvcc not found at $NVCC" >&2
    echo "install the CUDA toolkit env first:" >&2
    echo "  micromamba create -n elektron-cuda -c nvidia -c conda-forge \\" >&2
    echo "    cuda-nvcc cuda-cudart-dev cuda-cudart libcurl openssl cuda-version=12.9" >&2
    exit 1
fi

"$NVCC" \
    -ccbin "$HOSTCC" \
    -O3 -std=c++20 \
    -arch=sm_$ARCH \
    -I "$ENV_DIR/include" \
    -L "$ENV_DIR/lib" \
    -Xlinker -rpath -Xlinker "$ENV_DIR/lib" \
    "$SRC_DIR/miner_cuda.cu" \
    -o "$OUT_DIR/elektron_miner_cuda" \
    -lcurl -lssl -lcrypto -lpthread

echo "built: $OUT_DIR/elektron_miner_cuda"