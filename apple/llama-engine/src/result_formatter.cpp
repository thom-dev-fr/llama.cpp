#include "result_formatter.hpp"

#include "server-common.h"

#include <stdexcept>

namespace llama_engine {

using json = nlohmann::ordered_json;

std::string result_formatter::format_stream_chunk(server_task_result & res) {
    json chunk = res.to_json();
    return safe_json_to_str(chunk);
}

std::string result_formatter::format_non_stream(std::vector<server_task_result_ptr> & results) {
    if (results.empty()) {
        throw std::runtime_error("format_non_stream: empty results");
    }

    json arr = json::array();
    for (auto & r : results) {
        arr.push_back(r->to_json());
    }

    if (arr.size() == 1) {
        return safe_json_to_str(arr[0]);
    }

    // Merge extra choices into the first response, mirroring
    // server_routes::handle_completions_impl for the OAI chat path.
    json & choices = arr[0]["choices"];
    for (size_t i = 1; i < arr.size(); i++) {
        choices.push_back(std::move(arr[i]["choices"][0]));
    }
    return safe_json_to_str(arr[0]);
}

std::string result_formatter::format_error(server_task_result & res) {
    json body = res.to_json();
    json wrapped = {{"error", std::move(body)}};
    return safe_json_to_str(wrapped);
}

} // namespace llama_engine
