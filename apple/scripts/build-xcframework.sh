#!/usr/bin/env bash
# Build the LlamaEngineCore.xcframework containing the llama-engine library.
#
# Adapted from the root ./build-xcframework.sh. Differences:
#   - LLAMA_BUILD_APPLE_ENGINE=ON enables apple/llama-engine/
#   - Framework name is LlamaEngineCore, headers include llama_engine.h
#   - Supports iOS device, iOS simulator, and macOS (arm64 + x86_64).
#
# Run from the repo root: ./apple/scripts/build-xcframework.sh

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

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

OUT_DIR="${REPO_ROOT}/apple/build"

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
    -DLLAMA_BUILD_COMMON=ON
    -DLLAMA_BUILD_APPLE_ENGINE=ON
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
check_required_tool cmake  "Please install CMake 3.28+ (brew install cmake)"
check_required_tool xcrun  "Please install Xcode and CLT (xcode-select --install)"

# Clean previous builds
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
rm -rf build-ios-sim build-ios-device build-macos

setup_framework_structure() {
    local build_dir=$1
    local min_os_version=$2
    local platform=$3

    echo "Creating ${platform} framework structure for ${build_dir}..."

    local header_path=""
    local module_path=""
    local plist_path=""

    if [[ "${platform}" == "macos" ]]; then
        mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Headers"
        mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Modules"
        mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Resources"
        ln -sf A "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/Current"
        ln -sf Versions/Current/Headers   "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers"
        ln -sf Versions/Current/Modules   "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Modules"
        ln -sf Versions/Current/Resources "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Resources"
        ln -sf "Versions/Current/${FRAMEWORK_NAME}" \
               "${build_dir}/framework/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
        header_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Headers/"
        module_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Modules/"
        plist_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/Resources/Info.plist"
    else
        mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers"
        mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Modules"
        rm -rf "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions"
        header_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"
        module_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Modules/"
        plist_path="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Info.plist"
    fi

    cp apple/llama-engine/include/llama_engine.h "${header_path}"

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

combine_static_libraries() {
    local build_dir=$1
    local release_dir=$2
    local platform=$3
    local is_simulator=$4

    local output_lib=""
    if [[ "${platform}" == "macos" ]]; then
        output_lib="${build_dir}/framework/${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}"
    else
        output_lib="${build_dir}/framework/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
    fi

    local libs=(
        "${REPO_ROOT}/${build_dir}/apple/llama-engine/${release_dir}/libllama-engine.a"
        "${REPO_ROOT}/${build_dir}/common/${release_dir}/libllama-common.a"
        "${REPO_ROOT}/${build_dir}/common/${release_dir}/libllama-common-base.a"
        "${REPO_ROOT}/${build_dir}/vendor/cpp-httplib/${release_dir}/libcpp-httplib.a"
        "${REPO_ROOT}/${build_dir}/src/${release_dir}/libllama.a"
        "${REPO_ROOT}/${build_dir}/ggml/src/${release_dir}/libggml.a"
        "${REPO_ROOT}/${build_dir}/ggml/src/${release_dir}/libggml-base.a"
        "${REPO_ROOT}/${build_dir}/ggml/src/${release_dir}/libggml-cpu.a"
        "${REPO_ROOT}/${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a"
        "${REPO_ROOT}/${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a"
    )

    local temp_dir="${REPO_ROOT}/${build_dir}/temp"
    mkdir -p "${temp_dir}"
    xcrun libtool -static -o "${temp_dir}/combined.a" "${libs[@]}" 2>/dev/null

    local sdk archs min_version_flag install_name
    case "${platform}" in
        ios)
            if [[ "${is_simulator}" == "true" ]]; then
                sdk=iphonesimulator
                archs="arm64 x86_64"
                min_version_flag="-mios-simulator-version-min=${IOS_MIN_OS_VERSION}"
            else
                sdk=iphoneos
                archs="arm64"
                min_version_flag="-mios-version-min=${IOS_MIN_OS_VERSION}"
            fi
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

    echo "Linking dynamic framework binary for ${platform}..."
    xcrun -sdk "${sdk}" clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk ${sdk} --show-sdk-path)" \
        ${arch_flags} \
        ${min_version_flag} \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate \
        -install_name "${install_name}" \
        -o "${REPO_ROOT}/${output_lib}"

    mkdir -p "${REPO_ROOT}/${build_dir}/dSYMs"
    xcrun dsymutil "${REPO_ROOT}/${output_lib}" -o "${REPO_ROOT}/${build_dir}/dSYMs/${FRAMEWORK_NAME}.dSYM"
    xcrun strip -S "${REPO_ROOT}/${output_lib}" -o "${temp_dir}/stripped"
    mv "${temp_dir}/stripped" "${REPO_ROOT}/${output_lib}"
    rm -rf "${temp_dir}"
}

echo "== iOS simulator =="
cmake -B build-ios-sim -G Xcode \
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
cmake --build build-ios-sim --config Release -- -quiet

echo "== iOS device =="
cmake -B build-ios-device -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -S .
cmake --build build-ios-device --config Release -- -quiet

echo "== macOS =="
cmake -B build-macos -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -S .
cmake --build build-macos --config Release -- -quiet

setup_framework_structure "build-ios-sim"    "${IOS_MIN_OS_VERSION}"   "ios-sim"
setup_framework_structure "build-ios-device" "${IOS_MIN_OS_VERSION}"   "ios"
setup_framework_structure "build-macos"      "${MACOS_MIN_OS_VERSION}" "macos"

combine_static_libraries "build-ios-sim"    "Release-iphonesimulator" "ios"   "true"
combine_static_libraries "build-ios-device" "Release-iphoneos"        "ios"   "false"
combine_static_libraries "build-macos"      "Release"                 "macos" "false"

echo "== Assembling xcframework =="
xcodebuild -create-xcframework \
    -framework "build-ios-sim/framework/${FRAMEWORK_NAME}.framework"    \
        -debug-symbols "${REPO_ROOT}/build-ios-sim/dSYMs/${FRAMEWORK_NAME}.dSYM" \
    -framework "build-ios-device/framework/${FRAMEWORK_NAME}.framework" \
        -debug-symbols "${REPO_ROOT}/build-ios-device/dSYMs/${FRAMEWORK_NAME}.dSYM" \
    -framework "build-macos/framework/${FRAMEWORK_NAME}.framework"      \
        -debug-symbols "${REPO_ROOT}/build-macos/dSYMs/${FRAMEWORK_NAME}.dSYM" \
    -output "${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"

echo
echo "Done. xcframework at:"
echo "  ${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"
