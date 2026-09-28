# mtmd needs these even when common is not built
add_subdirectory(hash)
add_subdirectory(miniaudio)
add_subdirectory(nlohmann)
add_subdirectory(sheredom)
add_subdirectory(stb)

# Network acquisition is optional; local inference utilities do not need HTTP.
if (LLAMA_BUILD_COMMON OR LLAMA_BUILD_COMMON_ACQUISITION)
    add_subdirectory(cpp-httplib)
endif()
