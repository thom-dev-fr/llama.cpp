#include "common.h"
#include "log.h"
#include "download.h"
#include "hf-cache.h"

#include <algorithm>
#include <filesystem>
#include <future>
#include <regex>
#include <string>
#include <unordered_set>
#include <vector>

// Local side of model acquisition: HF repository references, GGUF file
// selection and the local cache. No network access; the network transport
// (llama-common-acquisition) is passed in explicitly where it may be used.

std::pair<std::string, std::string> common_download_split_repo_tag(const std::string & hf_repo_with_tag) {
    auto parts = string_split<std::string>(hf_repo_with_tag, ':');
    std::string tag = parts.size() > 1 ? parts.back() : "";
    std::string hf_repo = parts[0];
    if (string_split<std::string>(hf_repo, '/').size() != 2) {
        throw std::invalid_argument("error: invalid HF repo format, expected <user>/<model>[:quant]\n");
    }
    return {hf_repo, tag};
}

struct gguf_split_info {
    std::string prefix; // tag included
    std::string tag;
    int index;
    int count;
};

static gguf_split_info get_gguf_split_info(const std::string & path) {
    static const std::regex re_split("^(.+)-([0-9]{5})-of-([0-9]{5})$", std::regex::icase);
    static const std::regex re_tag("[-.]([A-Z0-9_]+)$", std::regex::icase);
    std::smatch m;

    std::string prefix = path;
    if (!string_remove_suffix(prefix, ".gguf")) {
        return {};
    }

    int index = 1;
    int count = 1;

    if (std::regex_match(prefix, m, re_split)) {
        index = std::stoi(m[2].str());
        count = std::stoi(m[3].str());
        prefix = m[1].str();
    }

    std::string tag;
    if (std::regex_search(prefix, m, re_tag)) {
        tag = m[1].str();
        for (char & c : tag) {
            c = std::toupper((unsigned char)c);
        }
    }

    return {std::move(prefix), std::move(tag), index, count};
}

// Q4_0 -> 4, F16 -> 16, NVFP4 -> 4, Q8_K_M -> 8, etc
static int extract_quant_bits(const std::string & filename) {
    auto split = get_gguf_split_info(filename);

    auto pos = split.tag.find_first_of("0123456789");
    if (pos == std::string::npos) {
        return 0;
    }

    return std::stoi(split.tag.substr(pos));
}

static hf_cache::hf_files get_split_files(const hf_cache::hf_files & files,
                                          const hf_cache::hf_file  & file) {
    auto split = get_gguf_split_info(file.path);

    if (split.count <= 1) {
        return {file};
    }
    hf_cache::hf_files result;

    for (const auto & f : files) {
        auto split_f = get_gguf_split_info(f.path);
        if (split_f.count == split.count && split_f.prefix == split.prefix) {
            result.push_back(f);
        }
    }
    return result;
}

// pick the best sibling GGUF whose filename contains `keyword` (e.g. "mmproj" / "mtp"),
// preferring deeper shared directory prefix with the model, then exact `tag` match,
// then closest quantization to the tag when given, or to the model otherwise
static hf_cache::hf_file find_best_sibling(const hf_cache::hf_files & files,
                                           const std::string        & model,
                                           const std::string        & keyword,
                                           const std::string        & tag = "") {
    hf_cache::hf_file best;
    size_t best_depth = 0;
    int best_diff = 0;
    bool best_exact = false;
    bool found = false;

    std::string tag_upper = tag;
    for (char & c : tag_upper) {
        c = (char) std::toupper((unsigned char) c);
    }

    int model_bits = 0;
    if (!tag_upper.empty()) {
        auto pos = tag_upper.find_first_of("0123456789");
        model_bits = pos == std::string::npos ? 0 : std::stoi(tag_upper.substr(pos));
    } else {
        model_bits = extract_quant_bits(model);
    }
    auto model_parts = string_split<std::string>(model, '/');
    auto model_dir = model_parts.end() - 1;

    for (const auto & f : files) {
        if (!string_ends_with(f.path, ".gguf") ||
            f.path.find(keyword) == std::string::npos) {
            continue;
        }

        auto sib_parts = string_split<std::string>(f.path, '/');
        auto sib_dir = sib_parts.end() - 1;

        auto [_, dir] = std::mismatch(model_parts.begin(), model_dir,
                                      sib_parts.begin(), sib_dir);
        if (dir != sib_dir) {
            continue;
        }

        size_t depth = dir - sib_parts.begin();
        auto bits = extract_quant_bits(f.path);
        auto diff = std::abs(bits - model_bits);

        std::string path_upper = f.path;
        for (char & c : path_upper) {
            c = (char) std::toupper((unsigned char) c);
        }
        bool exact = !tag_upper.empty() && path_upper.find("-" + tag_upper + ".") != std::string::npos;

        if (!found || depth > best_depth ||
            (depth == best_depth && exact && !best_exact) ||
            (depth == best_depth && exact == best_exact && diff < best_diff)) {
            best = f;
            best_depth = depth;
            best_diff = diff;
            best_exact = exact;
            found = true;
        }
    }
    return best;
}

static hf_cache::hf_file find_best_mmproj(const hf_cache::hf_files & files,
                                          const std::string        & model) {
    return find_best_sibling(files, model, "mmproj");
}

static hf_cache::hf_file find_best_mtp(const hf_cache::hf_files & files,
                                       const std::string        & model,
                                       const std::string        & tag = "") {
    return find_best_sibling(files, model, "mtp-", tag);
}

static hf_cache::hf_file find_best_eagle3(const hf_cache::hf_files & files,
                                          const std::string        & model,
                                          const std::string        & tag = "") {
    return find_best_sibling(files, model, "eagle3-", tag);
}

static hf_cache::hf_file find_best_dflash(const hf_cache::hf_files & files,
                                          const std::string        & model,
                                          const std::string        & tag = "") {
    return find_best_sibling(files, model, "dflash-", tag);
}

static hf_cache::hf_file find_best_dspark(const hf_cache::hf_files & files,
                                          const std::string        & model,
                                          const std::string        & tag = "") {
    return find_best_sibling(files, model, "dspark-", tag);
}

static bool gguf_filename_is_model(const std::string & filepath) {
    if (!string_ends_with(filepath, ".gguf")) {
        return false;
    }

    std::string filename = filepath;
    if (auto pos = filename.rfind('/'); pos != std::string::npos) {
        filename = filename.substr(pos + 1);
    }

    return filename.find("mmproj")  == std::string::npos &&
           filename.find("imatrix") == std::string::npos &&
           filename.find("mtp-")    == std::string::npos &&
           filename.find("eagle3-") == std::string::npos &&
           filename.find("dflash-") == std::string::npos &&
           filename.find("dspark-") == std::string::npos;
}

static hf_cache::hf_file find_best_model(const hf_cache::hf_files & files,
                                         const std::string        & tag) {
    std::vector<std::string> tags;

    if (!tag.empty()) {
        tags.push_back(tag);
    } else {
        tags = {"Q4_K_M", "Q8_0"};
    }

    for (const auto & t : tags) {
        std::regex pattern(t + "[.-]", std::regex::icase);
        for (const auto & f : files) {
            if (gguf_filename_is_model(f.path) &&
                std::regex_search(f.path, pattern)) {
                auto split = get_gguf_split_info(f.path);
                if (split.count > 1 && split.index != 1) {
                    continue;
                }
                return f;
            }
        }
    }

    // fallback to first available model only if tag is empty
    if (tag.empty()) {
        for (const auto & f : files) {
            if (gguf_filename_is_model(f.path)) {
                auto split = get_gguf_split_info(f.path);
                if (split.count > 1 && split.index != 1) {
                    continue;
                }
                return f;
            }
        }
    }

    return {};
}

static void list_available_gguf_files(const hf_cache::hf_files & files) {
    LOG_INF("Available GGUF files:\n");
    for (const auto & f : files) {
        if (string_ends_with(f.path, ".gguf")) {
            LOG_INF(" - %s\n", f.path.c_str());
        }
    }
}

common_download_hf_plan common_download_get_hf_plan(const common_params_model & model, const common_download_opts & opts,
                                                    const common_download_remote * remote) {
    common_download_hf_plan plan;
    hf_cache::hf_files all;

    auto [repo, tag] = common_download_split_repo_tag(model.hf_repo);

    if (!opts.offline && remote) {
        all = remote->get_repo_files(repo, opts.bearer_token);
    }
    if (all.empty()) {
        all = hf_cache::get_cached_files(repo);
    }
    if (all.empty()) {
        return plan;
    }

    // if preset.ini exists in the repo root, download only that file
    for (const auto & f : all) {
        if (f.path == "preset.ini") {
            plan.preset = f;
            return plan;
        }
    }

    hf_cache::hf_file primary;

    if (!model.hf_file.empty()) {
        for (const auto & f : all) {
            if (f.path == model.hf_file) {
                primary = f;
                break;
            }
        }
        if (primary.path.empty()) {
            LOG_ERR("%s: file '%s' not found in repository\n", __func__, model.hf_file.c_str());
            list_available_gguf_files(all);
            return plan;
        }
    } else {
        primary = find_best_model(all, tag);
        // a requested sidecar can resolve on its own, without a full model of the same tag
        if (primary.path.empty() && !opts.download_mtp && !opts.download_dflash && !opts.download_eagle3 && !opts.download_dspark) {
            LOG_ERR("%s: no GGUF files found in repository %s\n", __func__, repo.c_str());
            list_available_gguf_files(all);
            return plan;
        }
    }

    if (!primary.path.empty()) {
        plan.primary = primary;
        plan.model_files = get_split_files(all, primary);
    }

    if (opts.download_mmproj && !primary.path.empty()) {
        plan.mmproj = find_best_mmproj(all, primary.path);
    }
    if (opts.download_mtp) {
        plan.mtp = find_best_mtp(all, primary.path, tag);
    }
    if (opts.download_dflash) {
        plan.dflash = find_best_dflash(all, primary.path, tag);
    }
    if (opts.download_eagle3) {
        plan.eagle3 = find_best_eagle3(all, primary.path, tag);
    }
    if (opts.download_dspark) {
        plan.dspark = find_best_dspark(all, primary.path, tag);
    }

    if (primary.path.empty() &&
        plan.mtp.local_path.empty() && plan.dflash.local_path.empty() && plan.eagle3.local_path.empty() && plan.dspark.local_path.empty()) {
        LOG_ERR("%s: no GGUF files found in repository %s\n", __func__, repo.c_str());
        list_available_gguf_files(all);
    }

    return plan;
}

static bool is_http_status_ok(int status) {
    return status >= 200 && status < 400;
}

int common_download_file_cached(const std::string & url, const std::string & path, const common_download_opts & opts) {
    if (!std::filesystem::exists(std::filesystem::u8path(path))) {
        LOG_ERR("%s: required file is not available in cache (offline mode): %s\n", __func__, path.c_str());
        return -1;
    }

    LOG_DBG("%s: using cached file (offline mode): %s\n", __func__, path.c_str());

    // notify the callback that the file was cached
    if (opts.callback) {
        common_download_progress p;
        p.url = url;
        p.cached = true;
        opts.callback->on_start(p);
        opts.callback->on_done(p, true);
    }

    return 304; // Not Modified - fake cached response
}

void common_download_run_tasks(const std::vector<common_download_task> & tasks, const common_download_remote * remote) {
    std::vector<std::future<int>> futures;
    for (const auto & task : tasks) {
        futures.push_back(std::async(std::launch::async,
            [&task, remote]() {
                if (!remote) {
                    return common_download_file_cached(task.url, task.local_path, task.opts);
                }
                return remote->download_file(task.url, task.local_path, task.opts, task.is_hf);
            }
        ));
    }

    for (size_t i = 0; i < futures.size(); ++i) {
        std::string url = tasks[i].url;
        int status = futures[i].get();
        bool is_ok = is_http_status_ok(status);
        if (!is_ok && !remote) {
            throw common_download_unavailable(string_format(
                "'%s' is not available locally and network acquisition is not available in this build", url.c_str()));
        }
        if (!is_ok) {
            throw std::runtime_error(string_format("Download '%s' failed with status code: %d", url.c_str(), status));
        }
    }
}

std::vector<std::string> common_download_get_all_parts(const std::string & url) {
    auto split = get_gguf_split_info(url);

    if (split.count <= 1) {
        return {url};
    }

    std::vector<std::string> parts;
    for (int i = 1; i <= split.count; i++) {
        auto suffix = string_format("-%05d-of-%05d.gguf", i, split.count);
        parts.push_back(split.prefix + suffix);
    }
    return parts;
}

std::vector<common_cached_model_info> common_list_cached_models() {
    std::unordered_set<std::string> seen;
    std::vector<common_cached_model_info> result;

    auto files = hf_cache::get_cached_files();

    for (const auto & f : files) {
        auto split = get_gguf_split_info(f.path);
        if (split.index != 1 || split.tag.empty() ||
            split.prefix.find("mmproj")  != std::string::npos ||
            split.prefix.find("mtp-")    != std::string::npos ||
            split.prefix.find("eagle3-") != std::string::npos ||
            split.prefix.find("dflash-") != std::string::npos ||
            split.prefix.find("dspark-") != std::string::npos) {
            continue;
        }
        if (seen.insert(f.repo_id + ":" + split.tag).second) {
            result.push_back({f.repo_id, split.tag});
        }
    }

    return result;
}

std::string common_download_resolve_path(const std::string & hf_repo_with_tag, const std::string & hf_file) {
    auto [repo, tag] = common_download_split_repo_tag(hf_repo_with_tag);

    auto files = hf_cache::get_cached_files(repo);
    if (files.empty()) {
        return "";
    }

    if (!hf_file.empty()) {
        for (const auto & f : files) {
            if (f.path == hf_file) {
                return f.local_path;
            }
        }
        return "";
    }

    return find_best_model(files, tag).local_path;
}

bool common_download_remove(const std::string & hf_repo_with_tag) {
    namespace fs = std::filesystem;

    auto [repo_id, tag] = common_download_split_repo_tag(hf_repo_with_tag);

    if (tag.empty()) {
        return hf_cache::remove_cached_repo(repo_id);
    }

    std::string tag_upper = tag;
    for (char & c : tag_upper) {
        c = (char) std::toupper((unsigned char) c);
    }

    auto files = hf_cache::get_cached_files(repo_id);
    if (files.empty()) {
        return false;
    }

    // collect snapshot entries whose tag matches
    std::vector<fs::path> to_remove;
    for (const auto & f : files) {
        auto split = get_gguf_split_info(f.path);
        if (split.tag == tag_upper) {
            to_remove.emplace_back(f.local_path);
        }
    }

    if (to_remove.empty()) {
        return false;
    }

    // resolve blob paths from symlinks before deleting snapshot entries
    std::vector<fs::path> blobs_to_check;
    for (const auto & p : to_remove) {
        std::error_code ec;
        if (fs::is_symlink(p, ec)) {
            auto target = fs::read_symlink(p, ec);
            if (!ec) {
                blobs_to_check.push_back((p.parent_path() / target).lexically_normal());
            }
        }
    }

    // remove snapshot entries
    for (const auto & p : to_remove) {
        std::error_code ec;
        fs::remove(p, ec);
        if (ec) {
            LOG_WRN("%s: failed to remove %s: %s\n", __func__, p.string().c_str(), ec.message().c_str());
        }
    }

    if (blobs_to_check.empty()) {
        return true;
    }

    // collect blobs still referenced by remaining snapshot entries
    std::unordered_set<std::string> still_referenced;
    for (const auto & f : hf_cache::get_cached_files(repo_id)) {
        fs::path p(f.local_path);
        std::error_code ec;
        if (fs::is_symlink(p, ec)) {
            auto target = fs::read_symlink(p, ec);
            if (!ec) {
                still_referenced.insert((p.parent_path() / target).lexically_normal().string());
            }
        }
    }

    // remove orphaned blobs
    for (const auto & blob : blobs_to_check) {
        if (still_referenced.find(blob.string()) == still_referenced.end()) {
            std::error_code ec;
            fs::remove(blob, ec);
            if (ec) {
                LOG_WRN("%s: failed to remove blob %s: %s\n", __func__, blob.string().c_str(), ec.message().c_str());
            }
        }
    }

    return true;
}
