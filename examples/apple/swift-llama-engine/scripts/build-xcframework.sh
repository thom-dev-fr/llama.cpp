#!/usr/bin/env bash
# Build the LlamaEngineCore.xcframework containing the llama-engine library.
#
# Defaults to a production-ready Release xcframework with all supported slices:
# iOS device, iOS simulator, and macOS. Use --platform and --debug for faster
# single-platform development builds.
#
# Run from the repo root:
#   ./examples/apple/swift-llama-engine/scripts/build-xcframework.sh

set -euo pipefail

IOS_MIN_OS_VERSION=16.4
MACOS_MIN_OS_VERSION=13.3

BUILD_SHARED_LIBS=OFF
GGML_METAL=ON
GGML_METAL_EMBED_LIBRARY=ON
GGML_BLAS_DEFAULT=ON
GGML_METAL_USE_BF16=ON
GGML_OPENMP=OFF

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"
COMMON_CXX_FLAGS="${COMMON_C_FLAGS}"

FRAMEWORK_NAME="LlamaEngineCore"
CONFIGURATION="Release"
PLATFORM="all"
CLEAN=1

PACKAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "${PACKAGE_ROOT}/../../.." && pwd)"
cd "${REPO_ROOT}"

OUT_DIR="${PACKAGE_ROOT}/build"

usage() {
    cat <<EOF
Usage: $0 [options]

Build ${FRAMEWORK_NAME}.xcframework.

Defaults build a production-ready Release xcframework for all platforms.

Options:
  --platform <all|ios|ios-sim|macos>
      all      Build iOS device, iOS simulator, and macOS slices. Default.
      ios      Build iOS device arm64 only.
      ios-sim  Build iOS simulator arm64 + x86_64 only.
      macos    Build macOS arm64 + x86_64 only.
  --configuration <Release|Debug>
      Xcode configuration to build. Default: Release.
  --release
      Same as --configuration Release.
  --debug
      Same as --configuration Debug.
  --clean
      Remove selected native build directories before building. Default.
  --no-clean
      Preserve native build directories for incremental rebuilds.
  -h, --help
      Show this help.

Examples:
  $0
  $0 --platform ios --debug --no-clean
  $0 --platform macos --configuration Debug
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            if [[ $# -lt 2 ]]; then
                echo "Error: --platform requires a value." >&2
                usage >&2
                exit 2
            fi
            PLATFORM="$2"
            shift 2
            ;;
        --platform=*)
            PLATFORM="${1#*=}"
            shift
            ;;
        --configuration)
            if [[ $# -lt 2 ]]; then
                echo "Error: --configuration requires a value." >&2
                usage >&2
                exit 2
            fi
            CONFIGURATION="$2"
            shift 2
            ;;
        --configuration=*)
            CONFIGURATION="${1#*=}"
            shift
            ;;
        --release)
            CONFIGURATION="Release"
            shift
            ;;
        --debug)
            CONFIGURATION="Debug"
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --no-clean)
            CLEAN=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "${PLATFORM}" in
    all|ios|ios-sim|macos)
        ;;
    iphoneos|ios-device)
        PLATFORM=ios
        ;;
    iphonesimulator|simulator)
        PLATFORM=ios-sim
        ;;
    macosx)
        PLATFORM=macos
        ;;
    *)
        echo "Error: invalid platform '${PLATFORM}'." >&2
        usage >&2
        exit 2
        ;;
esac

case "${CONFIGURATION}" in
    Release|Debug)
        ;;
    release)
        CONFIGURATION=Release
        ;;
    debug)
        CONFIGURATION=Debug
        ;;
    *)
        echo "Error: invalid configuration '${CONFIGURATION}'. Use Release or Debug." >&2
        exit 2
        ;;
esac

COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT=dwarf-with-dsym
    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES
    -DCMAKE_XCODE_ATTRIBUTE_COPY_PHASE_STRIP=NO
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO
    -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS}
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_APP=OFF
    -DLLAMA_BUILD_COMMON=ON
    -DLLAMA_BUILD_MTMD=ON
    -DLLAMA_BUILD_ENGINE=ON
    -DLLAMA_HTTPLIB=OFF
    -DGGML_METAL_EMBED_LIBRARY=${GGML_METAL_EMBED_LIBRARY}
    -DGGML_BLAS_DEFAULT=${GGML_BLAS_DEFAULT}
    -DGGML_METAL=${GGML_METAL}
    -DGGML_METAL_USE_BF16=${GGML_METAL_USE_BF16}
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=${GGML_OPENMP}
    -DLLAMA_OPENSSL=OFF
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
check_required_tool xcodebuild "Please install Xcode."

selected_platforms() {
    case "${PLATFORM}" in
        all)
            echo "ios-sim ios macos"
            ;;
        *)
            echo "${PLATFORM}"
            ;;
    esac
}

build_dir_for_platform() {
    case "$1" in
        ios-sim)
            echo "build-ios-sim"
            ;;
        ios)
            echo "build-ios-device"
            ;;
        macos)
            echo "build-macos"
            ;;
    esac
}

product_dir_for_platform() {
    case "$1" in
        ios-sim)
            echo "${CONFIGURATION}-iphonesimulator"
            ;;
        ios)
            echo "${CONFIGURATION}-iphoneos"
            ;;
        macos)
            echo "${CONFIGURATION}"
            ;;
    esac
}

platform_label() {
    case "$1" in
        ios-sim)
            echo "iOS simulator"
            ;;
        ios)
            echo "iOS device"
            ;;
        macos)
            echo "macOS"
            ;;
    esac
}

framework_path_for_platform() {
    local build_dir=$1
    echo "${build_dir}/framework/${FRAMEWORK_NAME}.framework"
}

setup_framework_structure() {
    local build_dir=$1
    local min_os_version=$2
    local platform=$3

    echo "Creating $(platform_label "${platform}") framework structure for ${build_dir}..."

    rm -rf "${build_dir}/framework"

    local header_path=""
    local module_path=""
    local plist_path=""

    if [[ "${platform}" == "macos" ]]; then
        mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Headers"
        mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Modules"
        mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Resources"
        ln -sf A "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/Current"
        ln -sf Versions/Current/Headers "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers"
        ln -sf Versions/Current/Modules "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Modules"
        ln -sf Versions/Current/Resources "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Resources"
        ln -sf "Versions/Current/${FRAMEWORK_NAME}" \
               "${build_dir}/framework/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
        header_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Headers/"
        module_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Modules/"
        plist_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Resources/Info.plist"
    else
        mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers"
        mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Modules"
        header_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"
        module_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Modules/"
        plist_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Info.plist"
    fi

    cp engine/include/llama_engine.h "${header_path}"

    cat > "${module_path}module.modulemap" <<EOF
framework module ${FRAMEWORK_NAME} {
    umbrella header "llama_engine.h"
    export *
    module * { export * }

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"
}
EOF

    local platform_name sdk_name supported_platform device_family
    case "${platform}" in
        ios)
            platform_name=iphoneos
            sdk_name=iphoneos${min_os_version}
            supported_platform=iPhoneOS
            device_family='    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>'
            ;;
        ios-sim)
            platform_name=iphonesimulator
            sdk_name=iphonesimulator${min_os_version}
            supported_platform=iPhoneSimulator
            device_family='    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>'
            ;;
        macos)
            platform_name=macosx
            sdk_name=macosx${min_os_version}
            supported_platform=MacOSX
            device_family=""
            ;;
    esac

    cat > "${plist_path}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama.engine</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${min_os_version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${supported_platform}</string>
    </array>${device_family}
    <key>DTPlatformName</key>
    <string>${platform_name}</string>
    <key>DTSDKName</key>
    <string>${sdk_name}</string>
</dict>
</plist>
EOF
}

configure_and_build_platform() {
    local platform=$1
    local build_dir
    build_dir=$(build_dir_for_platform "${platform}")

    echo "== $(platform_label "${platform}") (${CONFIGURATION}) =="

    if [[ "${CLEAN}" == "1" ]]; then
        rm -rf "${build_dir}"
    fi

    case "${platform}" in
        ios-sim)
            cmake -B "${build_dir}" -G Xcode \
                "${COMMON_CMAKE_ARGS[@]}" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
                -DIOS=ON \
                -DCMAKE_SYSTEM_NAME=iOS \
                -DCMAKE_OSX_SYSROOT=iphonesimulator \
                -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
                -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphonesimulator \
                -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
                -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
                -S .
            ;;
        ios)
            cmake -B "${build_dir}" -G Xcode \
                "${COMMON_CMAKE_ARGS[@]}" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
                -DCMAKE_SYSTEM_NAME=iOS \
                -DCMAKE_OSX_SYSROOT=iphoneos \
                -DCMAKE_OSX_ARCHITECTURES="arm64" \
                -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos \
                -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
                -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
                -S .
            ;;
        macos)
            cmake -B "${build_dir}" -G Xcode \
                "${COMMON_CMAKE_ARGS[@]}" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
                -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
                -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
                -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
                -S .
            ;;
    esac

    cmake --build "${build_dir}" --config "${CONFIGURATION}" -- -quiet
}

combine_static_libraries() {
    local build_dir=$1
    local product_dir=$2
    local platform=$3

    local output_lib=""
    if [[ "${platform}" == "macos" ]]; then
        output_lib="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}"
    else
        output_lib="${build_dir}/framework/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
    fi

    local libs=(
        "${REPO_ROOT}/${build_dir}/engine/${product_dir}/libllama-engine.a"
        "${REPO_ROOT}/${build_dir}/tools/server/${product_dir}/libserver-context.a"
        "${REPO_ROOT}/${build_dir}/tools/mtmd/${product_dir}/libmtmd.a"
        "${REPO_ROOT}/${build_dir}/common/${product_dir}/libllama-common.a"
        "${REPO_ROOT}/${build_dir}/common/${product_dir}/libllama-common-base.a"
        "${REPO_ROOT}/${build_dir}/src/${product_dir}/libllama.a"
        "${REPO_ROOT}/${build_dir}/ggml/src/${product_dir}/libggml.a"
        "${REPO_ROOT}/${build_dir}/ggml/src/${product_dir}/libggml-base.a"
        "${REPO_ROOT}/${build_dir}/ggml/src/${product_dir}/libggml-cpu.a"
        "${REPO_ROOT}/${build_dir}/ggml/src/ggml-metal/${product_dir}/libggml-metal.a"
        "${REPO_ROOT}/${build_dir}/ggml/src/ggml-blas/${product_dir}/libggml-blas.a"
    )

    for lib in "${libs[@]}"; do
        if [[ ! -f "${lib}" ]]; then
            echo "Error: expected archive not found: ${lib}" >&2
            exit 1
        fi
    done

    local temp_dir="${REPO_ROOT}/${build_dir}/temp-xcframework"
    rm -rf "${temp_dir}"
    mkdir -p "${temp_dir}"
    xcrun libtool -static -o "${temp_dir}/combined.a" "${libs[@]}" 2>/dev/null

    local sdk archs min_version_flag install_name
    case "${platform}" in
        ios-sim)
            sdk=iphonesimulator
            archs="arm64 x86_64"
            min_version_flag="-mios-simulator-version-min=${IOS_MIN_OS_VERSION}"
            install_name="@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
            ;;
        ios)
            sdk=iphoneos
            archs="arm64"
            min_version_flag="-mios-version-min=${IOS_MIN_OS_VERSION}"
            install_name="@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
            ;;
        macos)
            sdk=macosx
            archs="arm64 x86_64"
            min_version_flag="-mmacosx-version-min=${MACOS_MIN_OS_VERSION}"
            install_name="@rpath/${FRAMEWORK_NAME}.framework/Versions/Current/${FRAMEWORK_NAME}"
            ;;
    esac

    local arch_flags=""
    for arch in ${archs}; do
        arch_flags+=" -arch ${arch}"
    done

    echo "Linking dynamic framework binary for $(platform_label "${platform}")..."
    xcrun -sdk "${sdk}" clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk ${sdk} --show-sdk-path)" \
        ${arch_flags} \
        ${min_version_flag} \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate \
        -install_name "${install_name}" \
        -o "${REPO_ROOT}/${output_lib}"

    rm -rf "${REPO_ROOT}/${build_dir}/dSYMs"
    mkdir -p "${REPO_ROOT}/${build_dir}/dSYMs"
    xcrun dsymutil "${REPO_ROOT}/${output_lib}" -o "${REPO_ROOT}/${build_dir}/dSYMs/${FRAMEWORK_NAME}.dSYM"

    if [[ "${CONFIGURATION}" == "Release" ]]; then
        xcrun strip -S "${REPO_ROOT}/${output_lib}" -o "${temp_dir}/stripped"
        mv "${temp_dir}/stripped" "${REPO_ROOT}/${output_lib}"
    fi

    rm -rf "${temp_dir}"
}

prepare_framework_for_platform() {
    local platform=$1
    local build_dir product_dir min_os_version
    build_dir=$(build_dir_for_platform "${platform}")
    product_dir=$(product_dir_for_platform "${platform}")

    case "${platform}" in
        ios|ios-sim)
            min_os_version=${IOS_MIN_OS_VERSION}
            ;;
        macos)
            min_os_version=${MACOS_MIN_OS_VERSION}
            ;;
    esac

    setup_framework_structure "${build_dir}" "${min_os_version}" "${platform}"
    combine_static_libraries "${build_dir}" "${product_dir}" "${platform}"
}

mkdir -p "${OUT_DIR}"
rm -rf "${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"

read -r -a PLATFORMS <<< "$(selected_platforms)"

for platform in "${PLATFORMS[@]}"; do
    configure_and_build_platform "${platform}"
done

for platform in "${PLATFORMS[@]}"; do
    prepare_framework_for_platform "${platform}"
done

xcframework_args=()
for platform in "${PLATFORMS[@]}"; do
    build_dir=$(build_dir_for_platform "${platform}")
    xcframework_args+=(
        -framework "$(framework_path_for_platform "${build_dir}")"
        -debug-symbols "${REPO_ROOT}/${build_dir}/dSYMs/${FRAMEWORK_NAME}.dSYM"
    )
done

if [[ "${#PLATFORMS[@]}" -eq 1 ]]; then
    echo "== Assembling $(platform_label "${PLATFORMS[0]}")-only xcframework =="
else
    echo "== Assembling xcframework =="
fi

xcodebuild -create-xcframework \
    "${xcframework_args[@]}" \
    -output "${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"

echo
echo "Done. xcframework at:"
echo "  ${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"
echo "Configuration: ${CONFIGURATION}"
echo "Platforms: ${PLATFORMS[*]}"
