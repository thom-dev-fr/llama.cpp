// The local cache must remain usable without HTTP, acquisition or argument parsing.
#include "common.h"
#include "hf-cache.h"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>

namespace fs = std::filesystem;

static void write_file(const fs::path & path, const std::string & data) {
    fs::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary);
    out << data;
    out.close();
    GGML_ASSERT(!out.fail());
}

int main() {
    const auto id = std::chrono::steady_clock::now().time_since_epoch().count();
    const fs::path root = fs::temp_directory_path() / ("test-hf-cache-" + std::to_string(id));
    GGML_ASSERT(fs::create_directory(root));
    const fs::path cache = root / "hub";
    common_set_env("LLAMA_CACHE", cache.string());

    // Merely consulting an explicitly selected, absent cache must not create it.
    GGML_ASSERT(hf_cache::get_cache_path() == cache.string());
    GGML_ASSERT(hf_cache::get_cached_files().empty());
    GGML_ASSERT(!fs::exists(cache));

    const std::string commit(40, 'a');
    const std::string other_commit(40, 'b');
    const fs::path repo = cache / "models--test--model";
    const fs::path snapshot = repo / "snapshots" / commit;
    const fs::path blob = repo / "blobs" / std::string(64, 'c');
    const fs::path outside = root / "keep.txt";
    write_file(outside, "keep");
    write_file(repo / "refs" / "main", commit);
    write_file(blob, "fixture data");

    hf_cache::hf_file file;
    file.repo_id = "test/model";
    file.path = "sub/model-Q8_0.gguf";
    file.local_path = blob.string();
    file.final_path = (snapshot / file.path).string();
    GGML_ASSERT(hf_cache::finalize_file(file) == file.final_path);
    GGML_ASSERT(fs::is_regular_file(file.final_path));
    GGML_ASSERT(fs::file_size(file.final_path) == 12);
    GGML_ASSERT(hf_cache::finalize_file(file) == file.final_path);

    const auto files = hf_cache::get_cached_files("test/model");
    GGML_ASSERT(files.size() == 1);
    GGML_ASSERT(files[0].repo_id == file.repo_id);
    GGML_ASSERT(files[0].path == file.path);
    GGML_ASSERT(files[0].local_path == file.final_path);
    GGML_ASSERT(hf_cache::get_cached_files().size() == 1);
    GGML_ASSERT(hf_cache::get_cached_files("test/absent").empty());

    // A valid main ref wins over another branch; an invalid main ref cannot be
    // used to traverse the filesystem and falls back to a valid branch.
    write_file(repo / "refs" / "other", other_commit);
    write_file(repo / "snapshots" / other_commit / "other.gguf", "other");
    GGML_ASSERT(hf_cache::get_cached_files("test/model")[0].path == file.path);
    write_file(repo / "refs" / "main", "../../outside");
    auto fallback = hf_cache::get_cached_files("test/model");
    GGML_ASSERT(fallback.size() == 1 && fallback[0].path == "other.gguf");

    for (const auto & invalid : {"../keep.txt", "test/../../keep.txt", "/test/model", "test/model/extra"}) {
        GGML_ASSERT(hf_cache::get_cached_files(invalid).empty());
        GGML_ASSERT(!hf_cache::remove_cached_repo(invalid));
        GGML_ASSERT(fs::is_regular_file(outside));
        GGML_ASSERT(fs::is_directory(repo));
    }

    hf_cache::hf_file missing;
    missing.local_path = (root / "absent").string();
    missing.final_path = (root / "not-created" / "absent").string();
    GGML_ASSERT(hf_cache::finalize_file(missing) == missing.final_path);
    GGML_ASSERT(!fs::exists(root / "not-created"));

    GGML_ASSERT(!hf_cache::remove_cached_repo("test/absent"));
    GGML_ASSERT(hf_cache::remove_cached_repo("test/model"));
    GGML_ASSERT(!fs::exists(repo));
    GGML_ASSERT(fs::is_regular_file(outside));
    GGML_ASSERT(hf_cache::get_cached_files().empty());
    fs::remove_all(root);
    return 0;
}
