#!/usr/bin/env bash
#
# Builds LlamaBridge.xcframework, the native part of the Swift package in
# bindings/apple: the C bridge (bindings/apple/bridge) over the llama.cpp engine,
# with llama, ggml (Metal, embedded shaders), mtmd and the local engine linked
# statically into one dynamic framework per slice.
#
# usage: scripts/build-apple-language-model.sh [--test] [--jobs N]
#
#   --test     also build the bridge for the host and run its lifetime tests
#              (needs LLAMA_BRIDGE_TEST_MODEL=/path/to/model.gguf)
#
# Outputs (only these paths are replaced; nothing else is cleaned):
#   build-apple-lm/<platform>-<arch>/                per-architecture CMake builds
#   build-apple-lm/{ios-device,ios-simulator,macos}/ merged frameworks and dSYMs
#   bindings/apple/Frameworks/LlamaBridge.xcframework  used by Package.swift
#   build-apple-lm/LlamaBridge.xcframework.zip         archive for a URL binary target
#   build-apple-lm/LlamaBridge.xcframework.zip.checksum   its SwiftPM checksum
#
# Slices: iOS device (arm64), iOS simulator (arm64, x86_64), macOS (arm64,
# x86_64), all with a minimum OS of 27.0 (APPLE_LM_MIN_OS), as the Swift package.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${ROOT}/build-apple-lm"
OUTPUT_DIR="${ROOT}/bindings/apple/Frameworks"
MIN_OS="${APPLE_LM_MIN_OS:-27.0}"
JOBS="$(sysctl -n hw.logicalcpu)"
RUN_TESTS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test) RUN_TESTS=1; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

for tool in cmake xcrun xcodebuild ditto; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 1; }
done

echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "Minimum OS: ${MIN_OS}"

# build_slice <name> <arch> <extra cmake args...>
build_slice() {
    local name="$1" arch="$2"; shift 2
    local dir="${BUILD_ROOT}/${name}"
    echo "==> ${name}"
    cmake -S "${ROOT}/bindings/apple/bridge" -B "${dir}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS=-g -DCMAKE_CXX_FLAGS=-g \
        -DCMAKE_OSX_ARCHITECTURES="${arch}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_OS}" \
        "$@" > "${dir}.configure.log" 2>&1 || { cat "${dir}.configure.log" >&2; exit 1; }
    cmake --build "${dir}" --target LlamaBridge -j "${JOBS}" > "${dir}.build.log" 2>&1 || { tail -50 "${dir}.build.log" >&2; exit 1; }
}

framework_binary() { # <framework dir>
    if [[ -d "$1/Versions" ]]; then echo "$1/Versions/A/LlamaBridge"; else echo "$1/LlamaBridge"; fi
}

# merge_slices <output name> <slice...>: one framework with every architecture, and its dSYM
merge_slices() {
    local name="$1"; shift
    local out="${BUILD_ROOT}/${name}"
    rm -rf "${out}"
    mkdir -p "${out}"
    cp -R "${BUILD_ROOT}/$1/LlamaBridge.framework" "${out}/"
    local binaries=()
    for slice in "$@"; do
        binaries+=("$(framework_binary "${BUILD_ROOT}/${slice}/LlamaBridge.framework")")
    done
    local binary
    binary="$(framework_binary "${out}/LlamaBridge.framework")"
    xcrun lipo -create "${binaries[@]}" -output "${binary}"
    xcrun dsymutil "${binary}" -o "${out}/LlamaBridge.framework.dSYM"
}

mkdir -p "${BUILD_ROOT}"

build_slice macos-arm64             arm64
build_slice macos-x86_64            x86_64
build_slice ios-device-arm64        arm64  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos
build_slice ios-simulator-arm64     arm64  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator
build_slice ios-simulator-x86_64    x86_64 -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator

merge_slices macos         macos-arm64 macos-x86_64
merge_slices ios-device    ios-device-arm64
merge_slices ios-simulator ios-simulator-arm64 ios-simulator-x86_64

echo "==> LlamaBridge.xcframework"
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/LlamaBridge.xcframework"
args=()
for slice in ios-device ios-simulator macos; do
    args+=(-framework "${BUILD_ROOT}/${slice}/LlamaBridge.framework"
           -debug-symbols "${BUILD_ROOT}/${slice}/LlamaBridge.framework.dSYM")
done
xcodebuild -create-xcframework "${args[@]}" -output "${OUTPUT_DIR}/LlamaBridge.xcframework"

echo "==> archive"
archive="${BUILD_ROOT}/LlamaBridge.xcframework.zip"
rm -f "${archive}" "${archive}.checksum"
(cd "${OUTPUT_DIR}" && ditto -c -k --sequesterRsrc --keepParent LlamaBridge.xcframework "${archive}")
checksum="$(xcrun swift package compute-checksum "${archive}")"
echo "${checksum}" > "${archive}.checksum"
echo "archive:  ${archive}"
echo "checksum: ${checksum}"

if [[ "${RUN_TESTS}" == 1 ]]; then
    : "${LLAMA_BRIDGE_TEST_MODEL:?set LLAMA_BRIDGE_TEST_MODEL to a local GGUF model}"
    echo "==> host tests"
    cmake -S "${ROOT}/bindings/apple/bridge" -B "${BUILD_ROOT}/host" -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_BRIDGE_TEST_MODEL="${LLAMA_BRIDGE_TEST_MODEL}" > "${BUILD_ROOT}/host.configure.log" 2>&1
    cmake --build "${BUILD_ROOT}/host" -j "${JOBS}" > "${BUILD_ROOT}/host.build.log" 2>&1
    (cd "${BUILD_ROOT}/host" && ctest --output-on-failure)
fi
