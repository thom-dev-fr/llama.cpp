#pragma once

#include <cstdint>
#include <string>
#include <vector>

using raw_buffer = std::vector<uint8_t>;

struct uploaded_file {
    raw_buffer data;
    std::string filename;
    std::string content_type;
};
