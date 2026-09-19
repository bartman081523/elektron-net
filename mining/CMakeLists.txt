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
    # Locate nvcc: -DCMAKE_CUDA_COMPILER=... wins, else $CUDACXX (as
    # documented above), else nvcc from PATH.
    if(NOT CMAKE_CUDA_COMPILER AND DEFINED ENV{CUDACXX})
        set(CMAKE_CUDA_COMPILER "$ENV{CUDACXX}" CACHE FILEPATH "nvcc (from $CUDACXX)")
    elseif(NOT CMAKE_CUDA_COMPILER)
        find_program(CMAKE_CUDA_COMPILER nvcc)
    endif()
    # nvcc rejects host compilers outside its supported gcc range (e.g. a
    # system g++ 15/16 next to nvcc 12.x). When nvcc lives in a
    # micromamba/conda env, use that env's own g++ as the host compiler --
    # same fallback logic as build-cuda.sh.
    if(CMAKE_CUDA_COMPILER AND NOT DEFINED CMAKE_CUDA_HOST_COMPILER)
        get_filename_component(_CUDA_BIN_DIR "${CMAKE_CUDA_COMPILER}" DIRECTORY)
        file(GLOB _CONDA_HOST_GXX "${_CUDA_BIN_DIR}/*-conda-*g++")
        if(_CONDA_HOST_GXX)
            list(GET _CONDA_HOST_GXX 0 _CONDA_HOST_GXX)
            set(CMAKE_CUDA_HOST_COMPILER "${_CONDA_HOST_GXX}" CACHE FILEPATH
                "nvcc host compiler (auto-detected from the nvcc conda env)")
            message(STATUS "CUDA host compiler: ${CMAKE_CUDA_HOST_COMPILER}")
        endif()
        unset(_CONDA_HOST_GXX)
        unset(_CUDA_BIN_DIR)
    endif()
    if(NOT CMAKE_CUDA_COMPILER OR NOT EXISTS "${CMAKE_CUDA_COMPILER}")
        message(FATAL_ERROR
            "ELEKTRON_BUILD_CUDA_MINER=ON but no CUDA compiler found. "
            "Set CUDACXX to the nvcc binary (e.g. the micromamba elektron-cuda env) "
            "or build with mining/build-cuda.sh instead.")
    endif()
    # A conda host compiler ships its own sysroot and does not see
    # /usr/include, so use the curl/OpenSSL headers shipped inside the nvcc
    # env (same layout as build-cuda.sh; with a system nvcc the system
    # headers are on the host compiler's default path).
    get_filename_component(_CUDA_ENV_DIR "${CMAKE_CUDA_COMPILER}/../.." ABSOLUTE)
    set(_CUDA_ENV_INC "")
    set(_CUDA_ENV_LIB "")
    if(EXISTS "${_CUDA_ENV_DIR}/include/curl/curl.h")
        set(_CUDA_ENV_INC "${_CUDA_ENV_DIR}/include")
        set(_CUDA_ENV_LIB "${_CUDA_ENV_DIR}/lib")
    elseif(EXISTS "${_CUDA_ENV_DIR}/Library/include/curl/curl.h")
        set(_CUDA_ENV_INC "${_CUDA_ENV_DIR}/Library/include")
        set(_CUDA_ENV_LIB "${_CUDA_ENV_DIR}/Library/lib")
    endif()
    enable_language(CUDA)
    add_executable(elektron_miner_cuda miner_cuda.cu)
    set_target_properties(elektron_miner_cuda PROPERTIES
        CUDA_STANDARD 20
        CUDA_ARCHITECTURES 75)
    target_link_libraries(elektron_miner_cuda PRIVATE Threads::Threads)
    if(_CUDA_ENV_INC)
        # Link the env's curl/OpenSSL (build-cuda.sh parity): the conda
        # linker does not see the system library search path, and the conda
        # host compiler does not see /usr/include.
        target_include_directories(elektron_miner_cuda PRIVATE "${_CUDA_ENV_INC}")
        target_link_directories(elektron_miner_cuda PRIVATE "${_CUDA_ENV_LIB}")
        set_target_properties(elektron_miner_cuda PROPERTIES
            BUILD_RPATH "${_CUDA_ENV_LIB}"
            INSTALL_RPATH "${_CUDA_ENV_LIB}")
        target_link_libraries(elektron_miner_cuda PRIVATE curl ssl crypto)
    else()
        target_link_libraries(elektron_miner_cuda PRIVATE
            CURL::libcurl
            OpenSSL::Crypto
        )
    endif()
    message(STATUS "CUDA miner enabled (arch ${CMAKE_CUDA_ARCHITECTURES})")
    unset(_CUDA_ENV_INC)
    unset(_CUDA_ENV_LIB)
    unset(_CUDA_ENV_DIR)
endif()