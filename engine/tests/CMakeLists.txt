# Unit tests for the pure modules of llama-engine.
# Does not load any GGUF model.

set(LLAMA_REPO_ROOT_T ${CMAKE_SOURCE_DIR})

add_executable(test-llama-engine-pure
    test_main.cpp
    test_params_translator.cpp
    test_engine_lifecycle.cpp
    test_inflight_registry.cpp
    test_chat_route_adapter.cpp
)

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
