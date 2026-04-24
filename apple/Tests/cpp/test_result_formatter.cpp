#include "test_util.hpp"

#include "result_formatter.hpp"

#include <nlohmann/json.hpp>

#include <memory>
#include <string>

using llama_engine::result_formatter;
using json = nlohmann::ordered_json;

// Minimal fake server_task_result that returns a fixed JSON object.
// We avoid touching the real partial/final classes since they bring in the
// full task_params serialisation path.
struct fake_result : server_task_result {
    json body;
    bool stop_flag = true;
    bool error_flag = false;
    fake_result(json b, bool stop, bool err) : body(std::move(b)), stop_flag(stop), error_flag(err) {
        id = 1;
    }
    bool is_stop() override  { return stop_flag; }
    bool is_error() override { return error_flag; }
    json to_json() override  { return body; }
};

static void test_stream_chunk_roundtrip() {
    CASE("format_stream_chunk emits JSON identical to to_json()");
    fake_result r({{"hello", "world"}, {"n", 42}}, false, false);
    std::string out = result_formatter::format_stream_chunk(r);
    auto parsed = json::parse(out);
    EXPECT_EQ(parsed.at("hello").get<std::string>(), std::string("world"));
    EXPECT_EQ(parsed.at("n").get<int>(), 42);
}

static void test_format_error_wraps_in_error_key() {
    CASE("format_error wraps body in {\"error\": ...}");
    fake_result r({{"message", "oops"}, {"code", 500}}, true, true);
    std::string out = result_formatter::format_error(r);
    auto parsed = json::parse(out);
    EXPECT(parsed.contains("error"));
    EXPECT_EQ(parsed.at("error").at("message").get<std::string>(), std::string("oops"));
    EXPECT_EQ(parsed.at("error").at("code").get<int>(), 500);
}

static void test_non_stream_single_passthrough() {
    CASE("format_non_stream with one result returns that object as-is");
    std::vector<server_task_result_ptr> results;
    results.push_back(std::make_unique<fake_result>(
        json{{"id", "abc"}, {"choices", json::array({json{{"index", 0}}})}}, true, false));
    std::string out = result_formatter::format_non_stream(results);
    auto parsed = json::parse(out);
    EXPECT_EQ(parsed.at("id").get<std::string>(), std::string("abc"));
    EXPECT_EQ(parsed.at("choices").size(), (size_t)1);
}

static void test_non_stream_merges_choices() {
    CASE("format_non_stream with multiple results merges choices into the first");
    std::vector<server_task_result_ptr> results;
    results.push_back(std::make_unique<fake_result>(
        json{{"id", "abc"}, {"choices", json::array({json{{"index", 0}, {"text", "A"}}})}}, true, false));
    results.push_back(std::make_unique<fake_result>(
        json{{"id", "abc"}, {"choices", json::array({json{{"index", 0}, {"text", "B"}}})}}, true, false));
    std::string out = result_formatter::format_non_stream(results);
    auto parsed = json::parse(out);
    EXPECT_EQ(parsed.at("choices").size(), (size_t)2);
    EXPECT_EQ(parsed.at("choices")[0].at("text").get<std::string>(), std::string("A"));
    EXPECT_EQ(parsed.at("choices")[1].at("text").get<std::string>(), std::string("B"));
}

static void test_non_stream_empty_throws() {
    CASE("format_non_stream with empty results throws");
    std::vector<server_task_result_ptr> results;
    bool caught = false;
    try {
        result_formatter::format_non_stream(results);
    } catch (const std::exception &) {
        caught = true;
    }
    EXPECT(caught);
}

void run_result_formatter_tests() {
    std::fprintf(stderr, "ResultFormatter:\n");
    test_stream_chunk_roundtrip();
    test_format_error_wraps_in_error_key();
    test_non_stream_single_passthrough();
    test_non_stream_merges_choices();
    test_non_stream_empty_throws();
}
