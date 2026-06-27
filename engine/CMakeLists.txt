cmake_minimum_required(VERSION 3.22)

# This target is added to the upstream build via a guarded add_subdirectory()
# in the root CMakeLists.txt (see LLAMA_BUILD_ENGINE). It links the reusable
# server-context and mtmd targets, so tools can stay disabled for xcframeworks.

project(llama-engine CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(LLAMA_ENGINE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
set(LLAMA_REPO_ROOT ${CMAKE_SOURCE_DIR})

set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

set(SERVER_DIR ${LLAMA_REPO_ROOT}/tools/server)

if (NOT TARGET mtmd)
    message(FATAL_ERROR "llama-engine requires the mtmd target. Configure with -DLLAMA_BUILD_MTMD=ON when LLAMA_BUILD_TOOLS=OFF.")
endif()
if (NOT TARGET server-context)
    message(FATAL_ERROR "llama-engine requires the server-context target")
endif()

if (COMMAND license_add_file AND COMMAND license_generate AND TARGET llama-common)
    file(GLOB EXTRA_LICENSES "${LLAMA_REPO_ROOT}/licenses/LICENSE-*")
    foreach(FILE_PATH ${EXTRA_LICENSES})
        get_filename_component(FILE_NAME "${FILE_PATH}" NAME)
        string(REGEX REPLACE "^LICENSE-" "" NAME "${FILE_NAME}")
        license_add_file("${NAME}" "${FILE_PATH}")
    endforeach()
    license_generate(llama-common)
endif()

set(LLAMA_ENGINE_SOURCES
    ${LLAMA_ENGINE_ROOT}/src/params_translator.cpp
    ${LLAMA_ENGINE_ROOT}/src/caps_probe.cpp
    ${LLAMA_ENGINE_ROOT}/src/chat_route_adapter.cpp
    ${LLAMA_ENGINE_ROOT}/src/engine_lifecycle.cpp
    ${LLAMA_ENGINE_ROOT}/src/inflight_registry.cpp
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
        ${LLAMA_REPO_ROOT}
        ${LLAMA_REPO_ROOT}/vendor
)

target_link_libraries(llama-engine
    PUBLIC
        llama
        ggml
    PRIVATE
        server-context
        Threads::Threads
)

target_compile_features(llama-engine PRIVATE cxx_std_17)

if (NOT MSVC)
    target_compile_options(llama-engine PRIVATE -Wno-cast-qual)
endif()

if (BUILD_SHARED_LIBS)
    set_target_properties(llama-engine PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()

if (ANDROID)
    target_compile_options(llama-engine PRIVATE -Wno-missing-prototypes)
endif()

option(LLAMA_BUILD_ENGINE_TESTS "Build llama-engine C++ unit tests" OFF)
if (LLAMA_BUILD_ENGINE_TESTS)
    enable_testing()
    add_subdirectory(${LLAMA_ENGINE_ROOT}/tests ${CMAKE_CURRENT_BINARY_DIR}/tests)
endif()
