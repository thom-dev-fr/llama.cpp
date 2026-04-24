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

set(SERVER_DIR ${LLAMA_REPO_ROOT}/tools/server)
set(MTMD_DIR   ${LLAMA_REPO_ROOT}/tools/mtmd)

set(MTMD_MODELS
    cogvlm.cpp
    conformer.cpp
    dotsocr.cpp
    gemma4a.cpp
    gemma4v.cpp
    glm4v.cpp
    hunyuanocr.cpp
    internvl.cpp
    kimivl.cpp
    kimik25.cpp
    nemotron-v2-vl.cpp
    llama4.cpp
    llava.cpp
    minicpmv.cpp
    paddleocr.cpp
    pixtral.cpp
    qwen2vl.cpp
    qwen3vl.cpp
    qwen3a.cpp
    step3vl.cpp
    siglip.cpp
    whisper-enc.cpp
    deepseekocr.cpp
    mobilenetv5.cpp
    youtuvl.cpp
    yasa2.cpp
)
list(TRANSFORM MTMD_MODELS PREPEND ${MTMD_DIR}/models/)

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
