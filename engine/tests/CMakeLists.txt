# Unit tests for the pure modules of llama-engine.
# Does not load any GGUF model.

set(LLAMA_REPO_ROOT_T ${CMAKE_SOURCE_DIR})

add_executable(test-llama-engine-pure
    test_main.cpp
    test_params_translator.cpp
    test_engine_lifecycle.cpp
    test_inflight_registry.cpp
    test_chat_route_adapter.cpp
    test_runtime_caps.cpp
)

# vocab-only GGUF shipped with the repo: metadata and tokenizer, no weights
target_compile_definitions(test-llama-engine-pure PRIVATE
    LLAMA_ENGINE_TEST_VOCAB="${LLAMA_REPO_ROOT_T}/models/ggml-vocab-qwen2.gguf")

target_include_directories(test-llama-engine-pure PRIVATE
    ${LLAMA_REPO_ROOT_T}/engine/include
    ${LLAMA_REPO_ROOT_T}/engine/src
    ${LLAMA_REPO_ROOT_T}/tools/server
    ${LLAMA_REPO_ROOT_T}/tools/mtmd
    ${LLAMA_REPO_ROOT_T}
    ${LLAMA_REPO_ROOT_T}/vendor
)

target_link_libraries(test-llama-engine-pure PRIVATE
    llama-engine
    llama-common
    Threads::Threads
)

target_compile_features(test-llama-engine-pure PRIVATE cxx_std_17)

add_test(NAME llama-engine-pure COMMAND test-llama-engine-pure)

# End-to-end C API test against a small real model. The model is fetched by a
# separate fixture, the test binary itself does no network access.
set(LLAMA_ENGINE_TEST_MODEL "" CACHE FILEPATH "llama-engine: model for the C API tests, empty to download stories15M")

add_executable(test-llama-engine-capi test_capi.c)
target_include_directories(test-llama-engine-capi PRIVATE ${LLAMA_REPO_ROOT_T}/engine/include)
target_link_libraries(test-llama-engine-capi PRIVATE llama-engine)
# the engine is a static C++ library: link with the C++ driver
set_target_properties(test-llama-engine-capi PROPERTIES LINKER_LANGUAGE CXX)

if (LLAMA_ENGINE_TEST_MODEL)
    set(LLAMA_ENGINE_CAPI_MODEL "${LLAMA_ENGINE_TEST_MODEL}")
else()
    # same fixture as tests/CMakeLists.txt
    set(LLAMA_ENGINE_CAPI_MODEL_NAME "tinyllamas/stories15M-q4_0.gguf")
    set(LLAMA_ENGINE_CAPI_MODEL      "${CMAKE_BINARY_DIR}/${LLAMA_ENGINE_CAPI_MODEL_NAME}")
    add_test(NAME llama-engine-download-model COMMAND ${CMAKE_COMMAND}
        -DDEST=${LLAMA_ENGINE_CAPI_MODEL}
        -DNAME=${LLAMA_ENGINE_CAPI_MODEL_NAME}
        -DHASH=SHA256=66967fbece6dbe97886593fdbb73589584927e29119ec31f08090732d1861739
        -P ${LLAMA_REPO_ROOT_T}/cmake/download-models.cmake
    )
    set_tests_properties(llama-engine-download-model PROPERTIES FIXTURES_SETUP llama-engine-model LABELS "engine;model")
endif()

add_test(NAME llama-engine-capi-cpu COMMAND test-llama-engine-capi "${LLAMA_ENGINE_CAPI_MODEL}" 0)
set_tests_properties(llama-engine-capi-cpu PROPERTIES SKIP_RETURN_CODE 77 LABELS "engine;model" FIXTURES_REQUIRED llama-engine-model TIMEOUT 600)

if (GGML_METAL)
    add_test(NAME llama-engine-capi-metal COMMAND test-llama-engine-capi "${LLAMA_ENGINE_CAPI_MODEL}" 99)
    set_tests_properties(llama-engine-capi-metal PROPERTIES SKIP_RETURN_CODE 77 LABELS "engine;model;metal" FIXTURES_REQUIRED llama-engine-model TIMEOUT 600)
endif()

set_tests_properties(llama-engine-pure PROPERTIES LABELS "engine")
