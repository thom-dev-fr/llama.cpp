cmake_minimum_required(VERSION 3.22)

# This target is added to the upstream build via a single-line guarded
# add_subdirectory() in the root CMakeLists.txt (see LLAMA_BUILD_APPLE_ENGINE).
# It pulls in the server-context and mtmd sources directly so it can be built
# with LLAMA_BUILD_TOOLS=OFF (the default for the xcframework build).

project(llama-engine CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(LLAMA_ENGINE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
set(LLAMA_REPO_ROOT ${CMAKE_SOURCE_DIR})

set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

set(SERVER_DIR ${LLAMA_REPO_ROOT}/tools/server)
set(MTMD_DIR   ${LLAMA_REPO_ROOT}/tools/mtmd)

# Automatically pick up all upstream MTMD model implementations.
# CONFIGURE_DEPENDS asks CMake to re-run configure when files are added/removed.
file(GLOB MTMD_MODELS CONFIGURE_DEPENDS
    "${MTMD_DIR}/models/*.cpp"
)
list(SORT MTMD_MODELS)

if (NOT MTMD_MODELS)
    message(FATAL_ERROR "No MTMD model sources found in ${MTMD_DIR}/models")
endif()

set(LLAMA_ENGINE_SOURCES
    ${SERVER_DIR}/server-chat.cpp
    ${SERVER_DIR}/server-task.cpp
    ${SERVER_DIR}/server-queue.cpp
    ${SERVER_DIR}/server-common.cpp
    ${SERVER_DIR}/server-context.cpp
    ${SERVER_DIR}/server-tools.cpp

    ${MTMD_DIR}/mtmd.cpp
    ${MTMD_DIR}/mtmd-audio.cpp
    ${MTMD_DIR}/mtmd-image.cpp
    ${MTMD_DIR}/mtmd-helper.cpp
    ${MTMD_DIR}/clip.cpp
    ${MTMD_MODELS}

    ${LLAMA_ENGINE_ROOT}/src/params_translator.cpp
    ${LLAMA_ENGINE_ROOT}/src/task_builder.cpp
    ${LLAMA_ENGINE_ROOT}/src/result_formatter.cpp
    ${LLAMA_ENGINE_ROOT}/src/engine_core.cpp
    ${LLAMA_ENGINE_ROOT}/src/llama_engine_capi.cpp
)

add_library(llama-engine STATIC ${LLAMA_ENGINE_SOURCES})

target_include_directories(llama-engine
    PUBLIC
        ${LLAMA_ENGINE_ROOT}/include
    PRIVATE
        ${LLAMA_ENGINE_ROOT}/src
        ${SERVER_DIR}
        ${MTMD_DIR}
        ${LLAMA_REPO_ROOT}
        ${LLAMA_REPO_ROOT}/vendor
)

target_link_libraries(llama-engine
    PUBLIC
        llama
        ggml
    PRIVATE
        llama-common
        Threads::Threads
)

target_compile_features(llama-engine PRIVATE cxx_std_17)

if (NOT MSVC)
    # stb_image / miniaudio warnings come from mtmd dependencies.
    target_compile_options(llama-engine PRIVATE -Wno-cast-qual)
endif()

if (BUILD_SHARED_LIBS)
    set_target_properties(llama-engine PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()

if (ANDROID)
    target_compile_options(llama-engine PRIVATE -Wno-missing-prototypes)
endif()

option(LLAMA_BUILD_APPLE_ENGINE_TESTS "Build llama-engine C++ unit tests" OFF)
if (LLAMA_BUILD_APPLE_ENGINE_TESTS)
    enable_testing()
    add_subdirectory(${LLAMA_REPO_ROOT}/apple/Tests/cpp ${CMAKE_CURRENT_BINARY_DIR}/tests)
endif()
