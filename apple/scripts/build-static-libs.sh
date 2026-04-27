#!/usr/bin/env bash
# Build the llama-engine static archives for a single Apple platform/arch.
#
# Faster alternative to build-xcframework.sh when you only need to iterate
# on the host (typically macOS arm64). Output is a flat directory of `.a`
# files that the SwiftPM `Package.swift` can link via `unsafeFlags` when
# `LLAMA_ENGINE_STATIC_LIBS_DIR` is set.
#
# Usage:
#     ./apple/scripts/build-static-libs.sh                # macOS, host arch
#     ./apple/scripts/build-static-libs.sh macos          # macOS, host arch
#     ./apple/scripts/build-static-libs.sh ios-sim        # iOS Simulator (host arch)
#     ./apple/scripts/build-static-libs.sh ios-device     # iOS device (arm64)
#
# Then point SwiftPM at the result:
#
#     export LLAMA_ENGINE_STATIC_LIBS_DIR="$PWD/apple/build/static-libs/<platform>"
#     cd apple/examples/LlamaChatDemo && swift run LlamaChatDemo

set -euo pipefail

PLATFORM="${1:-macos}"

IOS_MIN_OS_VERSION=16.4
MACOS_MIN_OS_VERSION=13.3

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

HOST_ARCH="$(uname -m)"

case "${PLATFORM}" in
    macos)
        BUILD_DIR="build-static-macos"
        OUT_DIR="apple/build/static-libs/macos"
        SDK_FLAGS=(
            -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION}
            -DCMAKE_OSX_ARCHITECTURES="${HOST_ARCH}"
        )
        ;;
    ios-sim)
        BUILD_DIR="build-static-ios-sim"
        OUT_DIR="apple/build/static-libs/ios-sim"
        SDK_FLAGS=(
            -DCMAKE_SYSTEM_NAME=iOS
            -DCMAKE_OSX_SYSROOT=iphonesimulator
            -DCMAKE_OSX_ARCHITECTURES="${HOST_ARCH}"
            -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION}
        )
        ;;
    ios-device)
        BUILD_DIR="build-static-ios-device"
        OUT_DIR="apple/build/static-libs/ios-device"
        SDK_FLAGS=(
            -DCMAKE_SYSTEM_NAME=iOS
            -DCMAKE_OSX_SYSROOT=iphoneos
            -DCMAKE_OSX_ARCHITECTURES="arm64"
            -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION}
        )
        ;;
    *)
        echo "Unknown platform '${PLATFORM}'. Expected: macos | ios-sim | ios-device" >&2
        exit 2
        ;;
esac

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"
COMMON_CXX_FLAGS="${COMMON_C_FLAGS}"

CMAKE_ARGS=(
    -DBUILD_SHARED_LIBS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_COMMON=ON
    -DLLAMA_BUILD_APPLE_ENGINE=ON
    -DLLAMA_HTTPLIB=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_METAL_USE_BF16=ON
    -DGGML_BLAS_DEFAULT=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DLLAMA_OPENSSL=OFF
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}"
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}"
)

check_required_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: $1 is required but not found." >&2
        echo "$2" >&2
        exit 1
    fi
}
check_required_tool cmake "Please install CMake 3.28+ (brew install cmake)"
check_required_tool xcrun "Please install Xcode and CLT (xcode-select --install)"

if command -v ninja &>/dev/null; then
    GENERATOR_ARGS=(-G Ninja)
else
    # default: Unix Makefiles, available out of the box with Xcode CLT
    GENERATOR_ARGS=(-G "Unix Makefiles")
fi

echo "== Configuring (${PLATFORM}, ${HOST_ARCH}) =="
rm -rf "${BUILD_DIR}"
cmake -B "${BUILD_DIR}" \
    "${GENERATOR_ARGS[@]}" \
    "${CMAKE_ARGS[@]}" \
    "${SDK_FLAGS[@]}" \
    -S .

echo "== Building =="
cmake --build "${BUILD_DIR}" --config Release --parallel

echo "== Collecting archives =="
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

LIBS=(
    "${BUILD_DIR}/apple/llama-engine/libllama-engine.a"
    "${BUILD_DIR}/common/libllama-common.a"
    "${BUILD_DIR}/common/libllama-common-base.a"
    "${BUILD_DIR}/src/libllama.a"
    "${BUILD_DIR}/ggml/src/libggml.a"
    "${BUILD_DIR}/ggml/src/libggml-base.a"
    "${BUILD_DIR}/ggml/src/libggml-cpu.a"
    "${BUILD_DIR}/ggml/src/ggml-metal/libggml-metal.a"
    "${BUILD_DIR}/ggml/src/ggml-blas/libggml-blas.a"
)

for lib in "${LIBS[@]}"; do
    if [[ ! -f "${lib}" ]]; then
        echo "Error: expected archive not found: ${lib}" >&2
        echo "(check that the CMake build above produced it)" >&2
        exit 1
    fi
    cp "${lib}" "${OUT_DIR}/"
done

echo
echo "Done. Static libs at:"
echo "  ${REPO_ROOT}/${OUT_DIR}"
echo
echo "To use from SwiftPM:"
echo "  export LLAMA_ENGINE_STATIC_LIBS_DIR=\"${REPO_ROOT}/${OUT_DIR}\""
echo "  cd apple/examples/LlamaChatDemo && swift run LlamaChatDemo"
