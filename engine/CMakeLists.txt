find_package(Threads REQUIRED)
llama_add_compile_flags()

# Shared decoder, request conversion, model catalog and the public lifetime API.
# Embedding applications see include/llama-engine.h only; the private types
# (server_* names inherited from llama-server) are for llama-engine-internal.
add_library(llama-engine
    engine-catalog.cpp
    engine-catalog.h
    engine-context.cpp
    engine-context.h
    engine-models.cpp
    engine-models.h
    engine-operations.cpp
    engine-operations.h
    engine-options.cpp
    engine-options.h
    engine-runtime.h
    engine-scheduler.h
    llama-engine.cpp
    ../include/llama-engine.h
    server-attachment.h
    server-chat.cpp
    server-chat.h
    server-common.cpp
    server-common.h
    server-queue.cpp
    server-queue.h
    server-schema.cpp
    server-schema.h
    server-task.cpp
    server-task.h
)

set_target_properties(llama-engine PROPERTIES
    VERSION ${LLAMA_VERSION_BASE}
    SOVERSION ${LLAMA_VERSION_MAJOR}
    MACHO_CURRENT_VERSION 0
)
# The public interface: include/llama-engine.h and nlohmann::json, nothing else.
target_include_directories(llama-engine
    PUBLIC  $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/include>
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(llama-engine PUBLIC vendor::nlohmann)
target_link_libraries(llama-engine PRIVATE llama-common-local mtmd Threads::Threads)
# Named options, presets and local model resolution (no network, no argv parsing).
target_link_libraries(llama-engine PRIVATE llama-common-options)
target_compile_features(llama-engine PUBLIC cxx_std_17)

if (TARGET llama-common-acquisition)
    target_link_libraries(llama-engine PRIVATE llama-common-acquisition)
    target_compile_definitions(llama-engine PRIVATE LLAMA_ENGINE_ACQUISITION)
endif()

if (BUILD_SHARED_LIBS)
    set_target_properties(llama-engine PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        WINDOWS_EXPORT_ALL_SYMBOLS ON
    )
endif()

install(TARGETS llama-engine LIBRARY)

install(FILES ../include/llama-engine.h DESTINATION include)

# Private interface of the engine, for its in-tree consumers that need more than
# the public API: the HTTP adapter of llama-server (native result formatting,
# multi-model routes) and the tests of internal races and policies. Not installed.
add_library(llama-engine-internal INTERFACE)
target_include_directories(llama-engine-internal INTERFACE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(llama-engine-internal INTERFACE llama-engine llama-common-local llama-common-options mtmd
                      Threads::Threads)
