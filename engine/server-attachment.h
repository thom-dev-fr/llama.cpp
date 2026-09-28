#pragma once

// Owned binary input shared with the HTTP adapter during extraction. These are
// private engine types, not the public request interface to be introduced in P2.
#include <cstdint>
#include <string>
#include <vector>

using raw_buffer = std::vector<uint8_t>;

struct uploaded_file {
    raw_buffer data;
    std::string filename;
    std::string content_type;
};
