cmake_minimum_required(VERSION 3.22)
project(elektron_miner CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)
find_package(CURL REQUIRED)
find_package(OpenSSL REQUIRED)

add_executable(elektron_miner miner.cpp)
target_link_libraries(elektron_miner PRIVATE
    Threads::Threads
    CURL::libcurl
    OpenSSL::SSL
    OpenSSL::Crypto
)

if(WIN32)
    target_link_libraries(elektron_miner PRIVATE ws2_32)
endif()

# Optional CUDA miner: elektron_miner_cuda (GPU sha256d, midstate + scan kernel).
# Requires the CUDA language to be usable, e.g.:
#   export CUDACXX=$HOME/micromamba/envs/elektron-cuda/bin/nvcc
#   export OPENSSL_ROOT_DIR=$HOME/micromamba/envs/elektron-cuda
#   cmake -B build -DELEKTRON_BUILD_CUDA_MINER=ON && cmake --build build
option(ELEKTRON_BUILD_CUDA_MINER "Build the CUDA GPU miner" OFF)

if(ELEKTRON_BUILD_CUDA_MINER)
    include(CheckLanguage)
    check_language(CUDA)
    if(CMAKE_CUDA_COMPILER)
        enable_language(CUDA)
        add_executable(elektron_miner_cuda miner_cuda.cu)
        set_target_properties(elektron_miner_cuda PROPERTIES
            CUDA_STANDARD 20
            CUDA_ARCHITECTURES 75)
        target_link_libraries(elektron_miner_cuda PRIVATE
            Threads::Threads
            CURL::libcurl
            OpenSSL::Crypto
        )
        message(STATUS "CUDA miner enabled (arch ${CMAKE_CUDA_ARCHITECTURES})")
    else()
        message(FATAL_ERROR
            "ELEKTRON_BUILD_CUDA_MINER=ON but no CUDA compiler found. "
            "Set CUDACXX to the nvcc binary (e.g. the micromamba elektron-cuda env) "
            "or build with mining/build-cuda.sh instead.")
    endif()
endif()