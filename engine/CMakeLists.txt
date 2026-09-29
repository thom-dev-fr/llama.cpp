find_package(Threads REQUIRED)
llama_add_compile_flags()

# Shared decoder, request conversion and public lifetime API. Historical server_*
# names remain private compatibility interfaces for the HTTP adapter until P8.
add_library(llama-engine
    engine-context.cpp
    engine-context.h
    engine-operations.cpp
    engine-operations.h
    engine-runtime.h
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
# Temporary visibility for the legacy adapter's private types, not installed as
# public headers. Only include/llama-engine.h is the embedding interface.
target_include_directories(llama-engine PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(llama-engine PUBLIC llama-common-local mtmd Threads::Threads vendor::nlohmann)
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
