# C bridge of the llama.cpp engine for the Apple bindings.
#
# Configured on its own (scripts/build-apple-language-model.sh): includes the
# repository as a subproject with only the local engine, then builds the
# dynamic LlamaBridge framework, which exports the llama_bridge_* functions and
# links everything else statically (llama, ggml with Metal, mtmd, engine).
cmake_minimum_required(VERSION 3.21)
project(llama-apple-bridge C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(BUILD_SHARED_LIBS               OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_ENGINE              ON  CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON_ACQUISITION  OFF CACHE BOOL "" FORCE) # downloads use URLSession (ADR 0003)
set(LLAMA_BUILD_COMMON              OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS               OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS               OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES            OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER              OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP                 OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_UI                  OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL                   OFF CACHE BOOL "" FORCE)
set(GGML_METAL                      ON  CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY        ON  CACHE BOOL "" FORCE)
set(GGML_NATIVE                     OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP                     OFF CACHE BOOL "" FORCE)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../.. llama EXCLUDE_FROM_ALL)

set(LLAMA_BRIDGE_VERSION "0.1.0" CACHE STRING "Version of the LlamaBridge framework")

if (CMAKE_SYSTEM_NAME STREQUAL "iOS")
    string(TOLOWER "${CMAKE_OSX_SYSROOT}" llama_bridge_sysroot)
    if (llama_bridge_sysroot MATCHES "iphonesimulator")
        set(LLAMA_BRIDGE_SUPPORTED_PLATFORM iPhoneSimulator)
    else()
        set(LLAMA_BRIDGE_SUPPORTED_PLATFORM iPhoneOS)
    endif()
else()
    set(LLAMA_BRIDGE_SUPPORTED_PLATFORM MacOSX)
endif()

add_library(LlamaBridge SHARED llama_bridge.cpp include/llama_bridge.h)
target_include_directories(LlamaBridge PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(LlamaBridge PRIVATE llama-engine)
set_target_properties(LlamaBridge PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    PUBLIC_HEADER include/llama_bridge.h
    MACOSX_FRAMEWORK_IDENTIFIER org.ggml.LlamaBridge
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING ${LLAMA_BRIDGE_VERSION}
    MACOSX_FRAMEWORK_BUNDLE_VERSION ${LLAMA_BRIDGE_VERSION}
    MACOSX_FRAMEWORK_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON)
# only the C interface is exported; the static dependencies stay private
target_link_options(LlamaBridge PRIVATE "LINKER:-exported_symbol,_llama_bridge_*" "LINKER:-dead_strip")

# The module map lets Swift import the framework as `LlamaBridge`.
set(LLAMA_BRIDGE_MODULEMAP ${CMAKE_CURRENT_BINARY_DIR}/module.modulemap)
file(WRITE ${LLAMA_BRIDGE_MODULEMAP} "framework module LlamaBridge {\n    header \"llama_bridge.h\"\n    export *\n}\n")
target_sources(LlamaBridge PRIVATE ${LLAMA_BRIDGE_MODULEMAP})
set_source_files_properties(${LLAMA_BRIDGE_MODULEMAP} PROPERTIES MACOSX_PACKAGE_LOCATION Modules)
if (NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # versioned (macOS) bundle: CMake links Headers and Resources, not Modules
    add_custom_command(TARGET LlamaBridge POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E create_symlink Versions/Current/Modules $<TARGET_BUNDLE_DIR:LlamaBridge>/Modules)
endif()

# Lifetime tests of the C interface, on the host.
if (NOT CMAKE_CROSSCOMPILING)
    enable_testing()
    find_package(Threads REQUIRED)
    add_executable(test-llama-bridge test-llama-bridge.c)
    target_link_libraries(test-llama-bridge PRIVATE LlamaBridge Threads::Threads)
    set(LLAMA_BRIDGE_TEST_MODEL "" CACHE FILEPATH "Local GGUF for the bridge tests")
    if (LLAMA_BRIDGE_TEST_MODEL)
        add_test(NAME test-llama-bridge COMMAND test-llama-bridge "${LLAMA_BRIDGE_TEST_MODEL}")
        set_tests_properties(test-llama-bridge PROPERTIES TIMEOUT 300)
    endif()
endif()
