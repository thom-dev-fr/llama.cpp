llama_add_compile_flags()

# server-core: single-model inference shared by llama-server and native consumers (private, not installed)

set(TARGET server-core)

add_library(${TARGET} STATIC
    server-attachment.h
    server-chat.cpp
    server-chat.h
    server-common.cpp
    server-common.h
    server-context.cpp
    server-context.h
    server-decision.cpp
    server-decision.h
    server-queue.cpp
    server-queue.h
    server-schema.cpp
    server-schema.h
    server-task.cpp
    server-task.h
)

if (BUILD_SHARED_LIBS)
    set_target_properties(${TARGET} PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()

target_include_directories(${TARGET} PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(${TARGET} PUBLIC llama-common mtmd ${CMAKE_THREAD_LIBS_INIT})
