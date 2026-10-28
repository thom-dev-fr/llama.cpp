#include "test_util.hpp"

#include "memory_measure.hpp"

#include <string>

using llama_engine::memory_measure;
using json = common_json;

static common_memory_breakdown_row make_row(common_memory_breakdown_row::kind_t kind, const char * name,
                                            size_t model, size_t context, size_t compute) {
    common_memory_breakdown_row r;
    r.kind    = kind;
    r.name    = name;
    r.model   = model;
    r.context = context;
    r.compute = compute;
    return r;
}

static void test_report_sums_rows_once() {
    CASE("report sums the rows once and keeps device capacity apart");
    memory_measure::measured m;
    auto dev = make_row(common_memory_breakdown_row::DEVICE, "MTL0", 6ull << 30, 1ull << 30, 512ull << 20);
    dev.total = 32ll << 30;
    dev.free  = 20ll << 30;
    m.rows.push_back(dev);
    m.rows.push_back(make_row(common_memory_breakdown_row::HOST, "Host", 100, 200, 300));
    m.rows.push_back(make_row(common_memory_breakdown_row::BUFFER_TYPE, "CPU_REPACK", 7, 0, 0));
    m.n_ctx       = 4096;
    m.n_ctx_train = 32768;

    common_params params;
    params.fit_params = false;
    json r = memory_measure::report(params, llama_model_default_params(), llama_context_default_params(), m);

    EXPECT_EQ(r.at("schema_version").get<int>(), 2);
    EXPECT_EQ(r.at("source").get<std::string>(), std::string("native"));
    EXPECT_EQ(r.at("rows").size(), (size_t) 3);
    EXPECT_EQ(r.at("rows").at(0).at("kind").get<std::string>(), std::string("device"));
    EXPECT_EQ(r.at("rows").at(0).at("device_total_bytes").get<uint64_t>(), (uint64_t) (32ull << 30));
    EXPECT(!r.at("rows").at(1).contains("device_total_bytes"));
    EXPECT_EQ(r.at("rows").at(2).at("kind").get<std::string>(), std::string("buffer_type"));

    const auto & req = r.at("required_bytes");
    EXPECT_EQ(req.at("model").get<uint64_t>(),   (uint64_t) ((6ull << 30) + 100 + 7));
    EXPECT_EQ(req.at("context").get<uint64_t>(), (uint64_t) ((1ull << 30) + 200));
    EXPECT_EQ(req.at("compute").get<uint64_t>(), (uint64_t) ((512ull << 20) + 300));
    EXPECT_EQ(req.at("total").get<uint64_t>(),
              (uint64_t) ((6ull << 30) + (1ull << 30) + (512ull << 20) + 100 + 200 + 300 + 7));

    EXPECT_EQ(r.at("effective").at("n_ctx").get<uint32_t>(), (uint32_t) 4096);
    EXPECT_EQ(r.at("effective").at("n_ctx_train").get<uint32_t>(), (uint32_t) 32768);
    EXPECT(r.at("complete").get<bool>());
    EXPECT(r.at("coverage").at("projector").get<bool>());
    EXPECT_EQ(req.at("projector").get<uint64_t>(), (uint64_t) 0);
    EXPECT_EQ(req.at("mtp_draft").get<uint64_t>(), (uint64_t) 0);
}

static void test_report_negative_free_and_partial_coverage() {
    CASE("negative free memory is clamped, an unmeasured projector and MTP make the report partial");
    memory_measure::measured m;
    auto dev = make_row(common_memory_breakdown_row::DEVICE, "GPU", 1, 2, 3);
    dev.total = 100;
    dev.free  = -5;
    m.rows.push_back(dev);

    common_params params;
    params.mmproj.path       = "/models/mmproj.gguf";
    params.speculative.types = { COMMON_SPECULATIVE_TYPE_DRAFT_MTP };
    json r = memory_measure::report(params, llama_model_default_params(), llama_context_default_params(), m);

    EXPECT_EQ(r.at("rows").at(0).at("device_free_bytes").get<uint64_t>(), (uint64_t) 0);
    EXPECT(!r.at("complete").get<bool>());
    EXPECT(!r.at("coverage").at("projector").get<bool>());
    EXPECT(!r.at("coverage").at("mtp_draft").get<bool>());
    EXPECT(r.at("coverage").at("model").get<bool>());
    EXPECT(r.at("warnings").size() >= 3);
}

static void test_report_adds_projector_and_mtp_draft() {
    CASE("a measured projector and MTP draft context are part of the total");
    memory_measure::measured m;
    m.rows.push_back(make_row(common_memory_breakdown_row::DEVICE, "MTL0", 1000, 200, 30));
    m.projector = 400;
    m.mtp_draft = 50;

    common_params params;
    params.fit_params        = false;
    params.mmproj.path       = "/models/mmproj.gguf";
    params.speculative.types = { COMMON_SPECULATIVE_TYPE_DRAFT_MTP };
    json r = memory_measure::report(params, llama_model_default_params(), llama_context_default_params(), m);

    const auto & req = r.at("required_bytes");
    EXPECT_EQ(req.at("model").get<uint64_t>(),     (uint64_t) 1000);
    EXPECT_EQ(req.at("projector").get<uint64_t>(), (uint64_t) 400);
    EXPECT_EQ(req.at("mtp_draft").get<uint64_t>(), (uint64_t) 50);
    EXPECT_EQ(req.at("total").get<uint64_t>(),     (uint64_t) (1000 + 200 + 30 + 400 + 50));
    EXPECT(r.at("complete").get<bool>());
    EXPECT(r.at("coverage").at("projector").get<bool>());
    EXPECT(r.at("coverage").at("mtp_draft").get<bool>());
}

static void test_report_names_a_failed_part() {
    CASE("a part that could not be measured keeps the total and says why");
    memory_measure::measured m;
    m.rows.push_back(make_row(common_memory_breakdown_row::DEVICE, "MTL0", 1000, 200, 30));
    m.projector       = 400;
    m.mtp_draft_error = "failed to create llama_context from model";

    common_params params;
    params.fit_params        = false;
    params.mmproj.path       = "/models/mmproj.gguf";
    params.speculative.types = { COMMON_SPECULATIVE_TYPE_DRAFT_MTP };
    json r = memory_measure::report(params, llama_model_default_params(), llama_context_default_params(), m);

    EXPECT_EQ(r.at("required_bytes").at("total").get<uint64_t>(), (uint64_t) (1000 + 200 + 30 + 400));
    EXPECT(!r.at("complete").get<bool>());
    EXPECT(r.at("coverage").at("projector").get<bool>());
    EXPECT(!r.at("coverage").at("mtp_draft").get<bool>());
    bool names_error = false;
    for (const auto & w : r.at("warnings")) {
        names_error = names_error || w.get<std::string>().find("failed to create llama_context") != std::string::npos;
    }
    EXPECT(names_error);
}

static void test_measure_invalid_config() {
    CASE("measure rejects an invalid config before touching the model");
    llama_engine_config cfg{};
    std::string out;
    std::string err;
    EXPECT_EQ((int) memory_measure::measure(cfg, out, err), (int) LLAMA_ENGINE_ERR_INVALID_ARG);
    EXPECT(out.empty());
    EXPECT(!err.empty());

    cfg.model_path    = "/nonexistent/model.gguf";
    cfg.kv_cache_type = (llama_engine_kv_type) 99;
    EXPECT_EQ((int) memory_measure::measure(cfg, out, err), (int) LLAMA_ENGINE_ERR_INVALID_ARG);

    char * json_out = nullptr;
    EXPECT_EQ((int) llama_engine_measure_memory(nullptr, &json_out, nullptr), (int) LLAMA_ENGINE_ERR_INVALID_ARG);
    EXPECT(json_out == nullptr);
}

void run_memory_measure_tests() {
    std::fprintf(stderr, "MemoryMeasure:\n");
    test_report_sums_rows_once();
    test_report_negative_free_and_partial_coverage();
    test_report_adds_projector_and_mtp_draft();
    test_report_names_a_failed_part();
    test_measure_invalid_config();
}
