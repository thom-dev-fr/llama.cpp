llama_add_compile_flags()

if (LLAMA_BUILD_COMMON)
    set(LLAMA_TEST_COMMON_TARGET llama-common)
else()
    set(LLAMA_TEST_COMMON_TARGET llama-common-local)
endif()

function(llama_build source)
    set(TEST_SOURCES ${source} ${ARGN})

    if (DEFINED LLAMA_TEST_NAME)
        set(TEST_TARGET ${LLAMA_TEST_NAME})
    else()
        get_filename_component(TEST_TARGET ${source} NAME_WE)
    endif()

    add_executable(${TEST_TARGET} ${TEST_SOURCES})
    target_link_libraries(${TEST_TARGET} PRIVATE llama ${LLAMA_TEST_COMMON_TARGET}) # TODO: [TAG_TESTS_LLAMA_LINK]
    if (LLAMA_TESTS_INSTALL)
        install(TARGETS ${TEST_TARGET} RUNTIME)
    endif()
endfunction()

function(llama_test target)
    include(CMakeParseArguments)
    set(options)
    set(oneValueArgs NAME LABEL WORKING_DIRECTORY)
    set(multiValueArgs ARGS)
    cmake_parse_arguments(LLAMA_TEST "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if (NOT DEFINED LLAMA_TEST_LABEL)
        set(LLAMA_TEST_LABEL "main")
    endif()
    if (NOT DEFINED LLAMA_TEST_WORKING_DIRECTORY)
        set(LLAMA_TEST_WORKING_DIRECTORY .)
    endif()
    if (DEFINED LLAMA_TEST_NAME)
        set(TEST_NAME ${LLAMA_TEST_NAME})
    else()
        set(TEST_NAME ${target})
    endif()

    set(TEST_TARGET ${target})

    add_test(
        NAME ${TEST_NAME}
        WORKING_DIRECTORY ${LLAMA_TEST_WORKING_DIRECTORY}
        COMMAND $<TARGET_FILE:${TEST_TARGET}>
        ${LLAMA_TEST_ARGS})

    set_property(TEST ${TEST_NAME} PROPERTY LABELS ${LLAMA_TEST_LABEL})
endfunction()

function(llama_test_cmd target)
    include(CMakeParseArguments)
    set(options)
    set(oneValueArgs NAME LABEL WORKING_DIRECTORY)
    set(multiValueArgs ARGS)
    cmake_parse_arguments(LLAMA_TEST "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if (NOT DEFINED LLAMA_TEST_LABEL)
        set(LLAMA_TEST_LABEL "main")
    endif()
    if (NOT DEFINED LLAMA_TEST_WORKING_DIRECTORY)
        set(LLAMA_TEST_WORKING_DIRECTORY .)
    endif()
    if (DEFINED LLAMA_TEST_NAME)
        set(TEST_NAME ${LLAMA_TEST_NAME})
    else()
        set(TEST_NAME ${target})
    endif()

    add_test(
        NAME ${TEST_NAME}
        WORKING_DIRECTORY ${LLAMA_TEST_WORKING_DIRECTORY}
        COMMAND ${target}
        ${LLAMA_TEST_ARGS})

    set_property(TEST ${TEST_NAME} PROPERTY LABELS ${LLAMA_TEST_LABEL})
endfunction()

# Builds and runs a test source file.
# Optional args:
# - NAME: name of the executable & test target (defaults to the source file name without extension)
# - LABEL: label for the test (defaults to main)
# - ARGS: arguments to pass to the test executable
# - WORKING_DIRECTORY
function(llama_build_and_test source)
    include(CMakeParseArguments)
    set(options)
    set(oneValueArgs NAME LABEL WORKING_DIRECTORY)
    set(multiValueArgs ARGS)
    cmake_parse_arguments(LLAMA_TEST "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    set(TEST_SOURCES ${source} ${LLAMA_TEST_UNPARSED_ARGUMENTS})

    if (NOT DEFINED LLAMA_TEST_LABEL)
        set(LLAMA_TEST_LABEL "main")
    endif()
    if (NOT DEFINED LLAMA_TEST_WORKING_DIRECTORY)
        set(LLAMA_TEST_WORKING_DIRECTORY .)
    endif()
    if (DEFINED LLAMA_TEST_NAME)
        set(TEST_TARGET ${LLAMA_TEST_NAME})
    else()
        get_filename_component(TEST_TARGET ${source} NAME_WE)
    endif()

    add_executable(${TEST_TARGET} ${TEST_SOURCES})
    if (LLAMA_TESTS_INSTALL)
        install(TARGETS ${TEST_TARGET} RUNTIME)
    endif()
    target_link_libraries(${TEST_TARGET} PRIVATE ${LLAMA_TEST_COMMON_TARGET})

    add_test(
        NAME ${TEST_TARGET}
        WORKING_DIRECTORY ${LLAMA_TEST_WORKING_DIRECTORY}
        COMMAND $<TARGET_FILE:${TEST_TARGET}>
        ${LLAMA_TEST_ARGS})

    set_property(TEST ${TEST_TARGET} PROPERTY LABELS ${LLAMA_TEST_LABEL})
endfunction()

if (LLAMA_BUILD_COMMON AND LLAMA_BUILD_TOOLS AND LLAMA_BUILD_SERVER AND NOT EMSCRIPTEN)
    add_executable(test-engine-replay test-engine-replay.cpp)
    target_link_libraries(test-engine-replay PRIVATE server-context)
    llama_test(test-engine-replay)
endif()

# This consumer must link only the local utilities, even in a full tools build.
if (TARGET llama-engine)
    add_executable(test-engine test-engine.cpp)
    target_link_libraries(test-engine PRIVATE llama-engine)
    llama_test(test-engine)
    # the documented example, built against the public interface only
    add_executable(test-engine-example ${PROJECT_SOURCE_DIR}/examples/engine-simple/engine-simple.cpp)
    target_link_libraries(test-engine-example PRIVATE llama-engine)
    add_executable(test-engine-lifecycle test-engine-lifecycle.cpp)
    target_link_libraries(test-engine-lifecycle PRIVATE llama-engine-internal)
    llama_test(test-engine-lifecycle)
    add_executable(test-engine-catalog test-engine-catalog.cpp)
    target_link_libraries(test-engine-catalog PRIVATE llama-engine)
    add_executable(test-engine-sources test-engine-sources.cpp)
    target_link_libraries(test-engine-sources PRIVATE llama-engine)
    add_executable(test-engine-options test-engine-options.cpp)
    target_link_libraries(test-engine-options PRIVATE llama-engine-internal)
    if (TARGET llama-common)
        # compares named options with argv parsing, which only executables link
        target_link_libraries(test-engine-options PRIVATE llama-common)
        target_compile_definitions(test-engine-options PRIVATE LLAMA_TEST_ARGV_PARITY)
    endif()
    add_executable(test-engine-models test-engine-models.cpp)
    target_link_libraries(test-engine-models PRIVATE llama-engine-internal)
    llama_test(test-engine-models)
    set_tests_properties(test-engine-models PROPERTIES TIMEOUT 120)
    set(LLAMA_ENGINE_TEST_MODEL "" CACHE FILEPATH "Local GGUF for engine integration tests")
    add_executable(test-engine-events test-engine-events.cpp)
    target_link_libraries(test-engine-events PRIVATE llama-engine-internal)
    add_test(NAME test-engine-events COMMAND test-engine-events "${PROJECT_SOURCE_DIR}/models/templates/Qwen-Qwen3-0.6B.jinja")
    add_executable(test-engine-fixtures test-engine-fixtures.cpp)
    target_link_libraries(test-engine-fixtures PRIVATE llama-engine)
    set(LLAMA_ENGINE_TEST_INFILL_MODEL "" CACHE FILEPATH "Local infill GGUF for engine tests")
    set(LLAMA_ENGINE_TEST_RERANK_MODEL "" CACHE FILEPATH "Local reranker GGUF for engine tests")
    set(LLAMA_ENGINE_TEST_VISION_MODEL "" CACHE FILEPATH "Local vision GGUF for engine tests")
    set(LLAMA_ENGINE_TEST_MMPROJ "" CACHE FILEPATH "Local projector GGUF for engine tests")
    foreach(family IN ITEMS INFILL RERANK)
        if (LLAMA_ENGINE_TEST_${family}_MODEL)
            string(TOLOWER "${family}" mode)
            add_test(NAME test-engine-${mode} COMMAND test-engine-fixtures "${mode}" "${LLAMA_ENGINE_TEST_${family}_MODEL}")
            set_tests_properties(test-engine-${mode} PROPERTIES TIMEOUT 120)
        endif()
    endforeach()
    if (LLAMA_ENGINE_TEST_VISION_MODEL AND LLAMA_ENGINE_TEST_MMPROJ)
        add_test(NAME test-engine-vision COMMAND test-engine-fixtures vision "${LLAMA_ENGINE_TEST_VISION_MODEL}"
            "${LLAMA_ENGINE_TEST_MMPROJ}" "${PROJECT_SOURCE_DIR}/tools/mtmd/tests/test-1-positive.png")
        set_tests_properties(test-engine-vision PROPERTIES TIMEOUT 120)
    endif()
    # representative chat model on the configured backend (tools, structured output,
    # reasoning, media, multi-model); arguments are documented in the source
    add_executable(test-engine-qualification test-engine-qualification.cpp)
    target_link_libraries(test-engine-qualification PRIVATE llama-engine)
    set(LLAMA_ENGINE_QUALIFY_ARGS "" CACHE STRING "Arguments of test-engine-qualification (--model ... ); empty: not run")
    if (LLAMA_ENGINE_QUALIFY_ARGS)
        separate_arguments(qualify_args UNIX_COMMAND "${LLAMA_ENGINE_QUALIFY_ARGS}")
        add_test(NAME test-engine-qualification COMMAND test-engine-qualification ${qualify_args})
        set_tests_properties(test-engine-qualification PROPERTIES TIMEOUT 1800 LABELS heavy)
    endif()
    add_executable(test-engine-operations test-engine-operations.cpp)
    target_link_libraries(test-engine-operations PRIVATE llama-engine)
    if (LLAMA_ENGINE_TEST_MODEL)
        if (LLAMA_BUILD_COMMON AND LLAMA_BUILD_TOOLS AND LLAMA_BUILD_SERVER AND NOT EMSCRIPTEN)
            add_executable(test-engine-transport test-engine-transport.cpp)
            target_link_libraries(test-engine-transport PRIVATE server-context)
            add_test(NAME test-engine-transport COMMAND test-engine-transport "${LLAMA_ENGINE_TEST_MODEL}")
            set_tests_properties(test-engine-transport PROPERTIES TIMEOUT 30)
        endif()
        add_test(NAME test-engine-operations COMMAND test-engine-operations "${LLAMA_ENGINE_TEST_MODEL}")
        set_tests_properties(test-engine-operations PROPERTIES TIMEOUT 120)
        add_test(NAME test-engine-model COMMAND test-engine "${LLAMA_ENGINE_TEST_MODEL}")
        add_test(NAME test-engine-example COMMAND test-engine-example -m "${LLAMA_ENGINE_TEST_MODEL}" -n 8)
        set_tests_properties(test-engine-example PROPERTIES TIMEOUT 60)
        set_tests_properties(test-engine-model PROPERTIES TIMEOUT 120)
        # with a projector, the catalog also reports the model's input modalities
        add_test(NAME test-engine-sources COMMAND test-engine-sources "${LLAMA_ENGINE_TEST_MODEL}" ${LLAMA_ENGINE_TEST_MMPROJ})
        set_tests_properties(test-engine-sources PROPERTIES TIMEOUT 180)
        if (TARGET llama-common-acquisition)
            # controlled HTTP endpoint on loopback; the engine itself links acquisition privately
            add_executable(test-engine-acquisition test-engine-acquisition.cpp)
            target_link_libraries(test-engine-acquisition PRIVATE llama-engine cpp-httplib)
            add_test(NAME test-engine-acquisition COMMAND test-engine-acquisition "${LLAMA_ENGINE_TEST_MODEL}")
            set_tests_properties(test-engine-acquisition PROPERTIES TIMEOUT 120)
        endif()
        add_test(NAME test-engine-options COMMAND test-engine-options "${LLAMA_ENGINE_TEST_MODEL}")
        set_tests_properties(test-engine-options PROPERTIES TIMEOUT 120)
        add_test(NAME test-engine-catalog COMMAND test-engine-catalog "${LLAMA_ENGINE_TEST_MODEL}")
        set_tests_properties(test-engine-catalog PROPERTIES TIMEOUT 180)
    endif()
    if (NOT LLAMA_ENGINE_TEST_MODEL)
        add_test(NAME test-engine-options COMMAND test-engine-options) # without the local resolution case
    endif()
endif()

add_executable(test-common-local test-common-local.cpp)
target_link_libraries(test-common-local PRIVATE llama-common-local)
llama_test(test-common-local)

add_executable(test-hf-cache test-hf-cache.cpp)
target_link_libraries(test-hf-cache PRIVATE llama-common-local)
llama_test(test-hf-cache)

if (TARGET llama-common-acquisition)
    add_executable(test-acquisition test-acquisition.cpp)
    target_link_libraries(test-acquisition PRIVATE llama-common-acquisition cpp-httplib)
    llama_test(test-acquisition)
endif()

if (TARGET llama-engine AND (NOT WIN32 OR NOT BUILD_SHARED_LIBS))
    add_executable(test-chat test-chat.cpp)
    target_link_libraries(test-chat PRIVATE llama-engine-internal)
    if (NOT TARGET llama-common-acquisition)
        target_compile_definitions(test-chat PRIVATE LLAMA_TEST_NO_ACQUISITION)
    endif()
    if (LLAMA_TESTS_INSTALL)
        install(TARGETS test-chat RUNTIME)
    endif()
    llama_test(test-chat WORKING_DIRECTORY ${PROJECT_SOURCE_DIR})
else()
    message(STATUS "test-chat requires llama-engine and support for internal test symbols")
endif()

if (NOT LLAMA_BUILD_COMMON)
    # Explicit local-only suite. Do not pull argument parsing, downloads or
    # server-context back into this profile through a test helper.
    message(STATUS "Local utilities tests: excluding executable tests (network tests require acquisition)")
    llama_build_and_test(test-chat-peg-parser.cpp peg-parser/simple-tokenize.cpp)
    llama_build_and_test(test-chat-auto-parser.cpp WORKING_DIRECTORY ${PROJECT_SOURCE_DIR})
    llama_build_and_test(test-chat-template.cpp)
    llama_build_and_test(test-jinja.cpp)
    llama_test(test-jinja NAME test-jinja-no-subprocess ARGS -py)
    set_tests_properties(test-jinja-no-subprocess PROPERTIES WILL_FAIL TRUE)
    llama_build_and_test(test-json-schema.cpp)
    llama_build_and_test(test-log.cpp)
    if (NOT WIN32 OR NOT BUILD_SHARED_LIBS)
        llama_build_and_test(test-sampling.cpp)
        llama_build_and_test(test-reasoning-budget.cpp)
        llama_build_and_test(test-grammar-parser.cpp)
        llama_build_and_test(test-grammar-integration.cpp)
        llama_build_and_test(test-llama-grammar.cpp)
        llama_build_and_test(test-json-schema-to-grammar.cpp)
    endif()
    return()
endif()

# build test-tokenizer-0 target once and add many tests
llama_build(test-tokenizer-0.cpp)

llama_test(test-tokenizer-0 NAME test-tokenizer-0-bert-bge          ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-bert-bge.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-command-r         ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-command-r.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-deepseek-coder    ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-deepseek-coder.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-deepseek-llm      ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-deepseek-llm.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-falcon            ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-falcon.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-gemma-4           ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-gemma-4.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-gpt-2             ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-gpt-2.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-llama-bpe         ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-llama-bpe.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-llama-spm         ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-llama-spm.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-mpt               ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-mpt.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-phi-3             ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-phi-3.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-qwen2             ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-qwen2.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-qwen35            ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-qwen35.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-refact            ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-refact.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-starcoder         ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-starcoder.gguf)

if (NOT WIN32)
    llama_test_cmd(
        ${CMAKE_CURRENT_SOURCE_DIR}/test-tokenizers-repo.sh
        NAME test-tokenizers-ggml-vocabs
        WORKING_DIRECTORY ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}
        ARGS https://huggingface.co/ggml-org/vocabs ${PROJECT_SOURCE_DIR}/models/ggml-vocabs
    )
endif()

if (LLAMA_LLGUIDANCE)
    llama_build_and_test(test-grammar-llguidance.cpp ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-llama-bpe.gguf)
endif ()

llama_build(test-recurrent-state-rollback.cpp)
llama_build(test-save-load-state.cpp)

if (NOT WIN32 OR NOT BUILD_SHARED_LIBS)
    # these tests are disabled on Windows because they use internal functions not exported with LLAMA_API (when building with shared libraries)
    llama_build_and_test(test-unicode.cpp)
    llama_build_and_test(test-sampling.cpp)
    llama_build_and_test(test-reasoning-budget.cpp)
    llama_build_and_test(test-grammar-parser.cpp)
    llama_build_and_test(test-grammar-integration.cpp)
    llama_build_and_test(test-llama-grammar.cpp)
    llama_build_and_test(test-batch-alloc.cpp)
    llama_build_and_test(test-json-schema-to-grammar.cpp)

    if (NOT GGML_BACKEND_DL)
        llama_build(test-quantize-stats.cpp)
    endif()

    llama_build(test-gbnf-validator.cpp)

    # build test-tokenizer-1-bpe target once and add many tests
    llama_build(test-tokenizer-1-bpe.cpp)

    # TODO: disabled due to slowness
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-aquila    ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-aquila.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-falcon    ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-falcon.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-gpt-2     ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-gpt-2.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-gpt-neox  ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-gpt-neox.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-llama-bpe ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-llama-bpe.gguf --ignore-merges)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-mpt       ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-mpt.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-refact    ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-refact.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-starcoder ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-starcoder.gguf)

    # build test-tokenizer-1-spm target once and add many tests
    llama_build(test-tokenizer-1-spm.cpp)

    llama_test(test-tokenizer-1-spm  NAME test-tokenizer-1-llama-spm ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-llama-spm.gguf)
    #llama_test(test-tokenizer-1-spm  NAME test-tokenizer-1-baichuan  ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-baichuan.gguf)

    # llama_build_and_test(test-double-float.cpp) # SLOW

    llama_build(test-llama-archs.cpp)

    set(MODEL_DIR "${CMAKE_CURRENT_BINARY_DIR}/test-models/")
    file(MAKE_DIRECTORY "${MODEL_DIR}")

    llama_test(
        test-llama-archs
        NAME test-generate-models
        LABEL main
        ARGS -o "${MODEL_DIR}"
    )
    set_tests_properties(test-generate-models PROPERTIES
        FIXTURES_SETUP generate-models
    )

    # Test recurrent-state rollback across all architectures, using the generated dummy models
    llama_test(
        test-recurrent-state-rollback
        LABEL main
        ARGS --models "${MODEL_DIR}"
    )
    set_tests_properties(test-recurrent-state-rollback PROPERTIES FIXTURES_REQUIRED generate-models)

    # Test state save/load functionality across all architectures, using the generated dummy models
    llama_test(
        test-save-load-state
        LABEL main
        ARGS --models "${MODEL_DIR}"
    )
    set_tests_properties(test-save-load-state PROPERTIES FIXTURES_REQUIRED generate-models)

    llama_build(test-fusion.cpp)
endif()

llama_build_and_test(test-chat-peg-parser.cpp peg-parser/simple-tokenize.cpp)
llama_build_and_test(test-jinja.cpp)
if (LLAMA_SUBPROCESS)
    llama_test(test-jinja NAME test-jinja-py ARGS -py LABEL python)
else()
    llama_test(test-jinja NAME test-jinja-no-subprocess ARGS -py)
    set_tests_properties(test-jinja-no-subprocess PROPERTIES WILL_FAIL TRUE)
endif()
llama_build_and_test(test-json-schema.cpp)
llama_build_and_test(test-chat-auto-parser.cpp WORKING_DIRECTORY ${PROJECT_SOURCE_DIR})
llama_build_and_test(test-chat-template.cpp)
# debug tool for chat template differential analysis (not registered as a test, run it manually)
llama_build(test-chat-analysis.cpp)
llama_build_and_test(test-log.cpp)
llama_build_and_test(
    test-peg-parser.cpp
    peg-parser/simple-tokenize.cpp
    peg-parser/test-basic.cpp
    peg-parser/test-gbnf-generation.cpp
    peg-parser/test-json-parser.cpp
    peg-parser/test-json-serialization.cpp
    peg-parser/test-python-dict-parser.cpp
    peg-parser/test-unicode.cpp
    peg-parser/tests.h
)

if (NOT ${CMAKE_SYSTEM_PROCESSOR} MATCHES "s390x")
    set(MODEL_NAME "tinyllamas/stories15M-q4_0.gguf")
    set(MODEL_HASH "SHA256=66967fbece6dbe97886593fdbb73589584927e29119ec31f08090732d1861739")
else()
    set(MODEL_NAME "tinyllamas/stories15M-be.Q4_0.gguf")
    set(MODEL_HASH "SHA256=9aec857937849d976f30397e97eb1cabb53eb9dcb1ce4611ba8247fb5f44c65d")
endif()
set(MODEL_DEST "${CMAKE_BINARY_DIR}/${MODEL_NAME}")

add_test(NAME test-download-model COMMAND ${CMAKE_COMMAND}
    -DDEST=${MODEL_DEST}
    -DNAME=${MODEL_NAME}
    -DHASH=${MODEL_HASH}
    -P ${PROJECT_SOURCE_DIR}/cmake/download-models.cmake
)
set_tests_properties(test-download-model PROPERTIES FIXTURES_SETUP test-download-model)

llama_build_and_test(test-thread-safety.cpp ARGS -m "${MODEL_DEST}" -ngl 99 -p "The meaning of life is" -n 128 -c 256 -ub 32 -np 4 -t 2)
set_tests_properties(test-thread-safety PROPERTIES FIXTURES_REQUIRED test-download-model)

llama_build_and_test(test-arg-parser.cpp)
llama_build_and_test(test-model-resolution.cpp)
# the test serves its repos from an httplib server, and the library links it privately
target_link_libraries(test-model-resolution PRIVATE cpp-httplib)

if (NOT LLAMA_SANITIZE_ADDRESS AND NOT GGML_SCHED_NO_REALLOC)
  # TODO: repair known memory leaks
  llama_build_and_test(test-opt.cpp)
endif()

# TODO: make this test (and others) not link `libllama` as it is not needed [TAG_TESTS_LLAMA_LINK]
llama_build(test-backend-ops.cpp)

llama_build_and_test(test-tiled-mulmat.cpp)
llama_build_and_test(test-model-load-cancel.cpp LABEL "model")
llama_build_and_test(test-autorelease.cpp       LABEL "model")
llama_build_and_test(test-backend-sampler.cpp   LABEL "model")

# Test for state restore with fragmented KV cache
# Requires a model, uses same args pattern as test-thread-safety
# TODO: run on all dummy models
llama_build_and_test(test-state-restore-fragmented.cpp LABEL "model" ARGS -m "${MODEL_DEST}")
set_tests_properties(test-state-restore-fragmented PROPERTIES FIXTURES_REQUIRED test-download-model)

if (APPLE)
    llama_build(test-rset-release.cpp)
endif()

if (NOT GGML_BACKEND_DL AND GGML_CPU)
    # these tests use the backends directly and cannot be built with dynamic loading
    llama_build_and_test(test-barrier.cpp)
    llama_build_and_test(test-quantize-fns.cpp)
    llama_build_and_test(test-quantize-perf.cpp)
    llama_build_and_test(test-rope.cpp)
    llama_build_and_test(test-col2im-1d.cpp)
endif()

# libmtmd
set(LLAMA_TEST_NAME test-mtmd-c-api)
llama_build_and_test(test-mtmd-c-api.c)
target_link_libraries(${LLAMA_TEST_NAME} PRIVATE mtmd)
unset(LLAMA_TEST_NAME)

llama_build_and_test(test-mtmd-impl.cpp)
target_link_libraries(test-mtmd-impl PRIVATE mtmd)

# GGUF model data fetcher library for tests that need real model metadata
# Only compile when cpp-httplib has SSL support (CPPHTTPLIB_OPENSSL_SUPPORT)
if (TARGET cpp-httplib)
    get_target_property(_cpp_httplib_defs cpp-httplib INTERFACE_COMPILE_DEFINITIONS)
    if (_cpp_httplib_defs MATCHES "CPPHTTPLIB_OPENSSL_SUPPORT")
        add_library(gguf-model-data STATIC gguf-model-data.cpp)
        target_link_libraries(gguf-model-data PRIVATE llama-common cpp-httplib)
        target_include_directories(gguf-model-data PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

        add_executable(test-gguf-model-data test-gguf-model-data.cpp)
        target_link_libraries(test-gguf-model-data PRIVATE gguf-model-data llama-common)
        llama_test(test-gguf-model-data LABEL "model")

        # test-quant-type-selection requires gguf-model-data for remote model metadata
        llama_build_and_test(test-quant-type-selection.cpp LABEL "model")
        target_link_libraries(test-quant-type-selection PRIVATE gguf-model-data)
        target_compile_definitions(test-quant-type-selection PRIVATE
            SNAPSHOT_DIR="${CMAKE_CURRENT_SOURCE_DIR}/snapshots")
    endif()
endif()

# dummy executable - not installed
get_filename_component(TEST_TARGET test-c.c NAME_WE)
add_executable(${TEST_TARGET} test-c.c)
target_link_libraries(${TEST_TARGET} PRIVATE llama)

if (NOT LLAMA_USE_SYSTEM_GGML)
    # Needs non-public ggml-impl.h
    llama_build_and_test(test-gguf.cpp)

    # Needs non-public ggml{,-backend}-impl.h
    llama_build_and_test(test-alloc.cpp)
endif()

llama_build(test-export-graph-ops.cpp)
if (TARGET gguf-model-data)
    target_link_libraries(test-export-graph-ops PRIVATE gguf-model-data)
    target_compile_definitions(test-export-graph-ops PRIVATE LLAMA_HF_FETCH)
endif()
