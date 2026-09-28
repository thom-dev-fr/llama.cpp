find_package(Threads REQUIRED)
llama_add_compile_flags()

# First extraction lot: request conversion, tasks and queues. The decoder loop
# and the public lifetime/request interface follow in P2; these headers remain
# private compatibility interfaces for the existing HTTP adapter until P8.
add_library(llama-engine
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
# public headers. The limited public interface is introduced separately in P2.
target_include_directories(llama-engine PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(llama-engine PUBLIC llama-common-local mtmd Threads::Threads)
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
