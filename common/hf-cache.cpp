#include "hf-cache.h"
#include "hf-cache-internal.h"

#include "build-info.h"
#include "common.h"
#include "log.h"
#include "http.h"
#include "json.h"

#include <filesystem>
#include <fstream>
#include <string>
#include <stdexcept>

namespace hf_cache {

namespace fs = std::filesystem;

static bool is_valid_hf_token(const std::string & token) {
    if (token.length() < 37 || token.length() > 256 ||
        !string_starts_with(token, "hf_")) {
        return false;
    }
    for (size_t i = 3; i < token.length(); ++i) {
        if (!detail::is_alphanum(token[i])) {
            return false;
        }
    }
    return true;
}

static bool is_valid_subpath(const fs::path & path, const fs::path & subpath) {
    if (subpath.is_absolute()) {
        return false; // never do a / b with b absolute
    }
    auto b = fs::absolute(path).lexically_normal();
    auto t = (b / subpath).lexically_normal();
    auto [b_end, _] = std::mismatch(b.begin(), b.end(), t.begin(), t.end());

    return b_end == b.end();
}

static common_json api_get(const std::string & url,
                           const std::string & token) {
    auto [cli, parts] = common_http_client(url);

    httplib::Headers headers = {
        {"User-Agent", "llama-cpp/" + std::string(llama_build_info())},
        {"Accept", "application/json"}
    };

    if (is_valid_hf_token(token)) {
        headers.emplace("Authorization", "Bearer " + token);
    } else if (!token.empty()) {
        LOG_WRN("%s: invalid token, authentication disabled\n", __func__);
    }

    if (auto res = cli.Get(parts.path, headers)) {
        auto body = res->body;

        if (res->status == 200) {
            return common_json::parse(res->body);
        }
        try {
            body = common_json::parse(res->body)["error"].get<std::string>();
        } catch (...) { }

        throw std::runtime_error("GET failed (" + std::to_string(res->status) + "): " + body);
    } else {
        throw std::runtime_error("HTTPLIB failed: " + httplib::to_string(res.error()));
    }
}

static std::string get_repo_commit(const std::string & repo_id,
                                   const std::string & token) {
    try {
        auto endpoint = common_get_model_endpoint();
        auto json = api_get(endpoint + "api/models/" + repo_id + "/refs", token);

        if (!json.is_object() ||
            !json.contains("branches") || !json["branches"].is_array()) {
            LOG_WRN("%s: missing 'branches' for '%s'\n", __func__, repo_id.c_str());
            return {};
        }

        fs::path refs_path = detail::get_repo_path(repo_id) / "refs";
        std::string name;
        std::string commit;
        fs::path name_path;

        for (const auto & branch : json["branches"]) {
            if (!branch.is_object() ||
                !branch.contains("name") || !branch["name"].is_string() ||
                !branch.contains("targetCommit") || !branch["targetCommit"].is_string()) {
                continue;
            }
            std::string _name = branch["name"].get<std::string>();
            std::string _commit = branch["targetCommit"].get<std::string>();

            if (!detail::is_valid_commit(_commit)) {
                LOG_WRN("%s: skip invalid commit: %s\n", __func__, _commit.c_str());
                continue;
            }
            const fs::path candidate = fs::u8path(_name);

            if (!is_valid_subpath(refs_path, candidate)) {
                LOG_WRN("%s: skip invalid branch: %s\n", __func__, _name.c_str());
                continue;
            }

            if (_name == "main") {
                name = _name;
                commit = _commit;
                name_path = candidate;
                break;
            }

            if (name.empty() || commit.empty()) {
                name = _name;
                commit = _commit;
                name_path = candidate;
            }
        }

        if (name.empty() || commit.empty()) {
            LOG_WRN("%s: no valid branch for '%s'\n", __func__, repo_id.c_str());
            return {};
        }

        fs_write_atomic(refs_path / name_path, commit);
        return commit;

    } catch (const common_json_error & e) {
        LOG_ERR("%s: JSON error: %s\n", __func__, e.what());
    } catch (const std::exception & e) {
        LOG_ERR("%s: error: %s\n", __func__, e.what());
    }
    return {};
}

hf_files get_repo_files(const std::string & repo_id,
                        const std::string & token) {
    if (!detail::is_valid_repo_id(repo_id)) {
        LOG_WRN("%s: invalid repository: %s\n", __func__, repo_id.c_str());
        return {};
    }

    std::string commit = get_repo_commit(repo_id, token);
    if (commit.empty()) {
        LOG_WRN("%s: failed to resolve commit for %s\n", __func__, repo_id.c_str());
        return {};
    }

    fs::path blobs_path = detail::get_repo_path(repo_id) / "blobs";
    fs::path commit_path = detail::get_repo_path(repo_id) / "snapshots" / commit;

    hf_files files;

    try {
        auto endpoint = common_get_model_endpoint();
        auto json = api_get(endpoint + "api/models/" + repo_id + "/tree/" + commit + "?recursive=true", token);

        if (!json.is_array()) {
            LOG_WRN("%s: response is not an array for '%s'\n", __func__, repo_id.c_str());
            return {};
        }

        for (const auto & item : json) {
            if (!item.is_object() ||
                !item.contains("type") || !item["type"].is_string() || item["type"] != "file" ||
                !item.contains("path") || !item["path"].is_string()) {
                continue;
            }

            hf_file file;
            file.repo_id = repo_id;
            file.path = item["path"].get<std::string>();

            const fs::path subpath = fs::u8path(file.path);

            if (!is_valid_subpath(commit_path, subpath)) {
                LOG_WRN("%s: skip invalid path: %s\n", __func__, file.path.c_str());
                continue;
            }

            if (item.contains("lfs") && item["lfs"].is_object()) {
                if (item["lfs"].contains("oid") && item["lfs"]["oid"].is_string()) {
                    file.oid = item["lfs"]["oid"].get<std::string>();
                }
            } else if (item.contains("oid") && item["oid"].is_string()) {
                file.oid = item["oid"].get<std::string>();
            }

            if (!file.oid.empty() && !detail::is_valid_oid(file.oid)) {
                LOG_WRN("%s: skip invalid oid: %s\n", __func__, file.oid.c_str());
                continue;
            }

            file.url = endpoint + repo_id + "/resolve/" + commit + "/" + file.path;

            fs::path final_path = commit_path / subpath;
            file.final_path = fs_path_to_utf8(final_path);

            if (!file.oid.empty() && !fs::exists(final_path)) {
                fs::path local_path = blobs_path / file.oid;
                file.local_path = fs_path_to_utf8(local_path);
            } else {
                file.local_path = file.final_path;
            }

            files.push_back(file);
        }
    } catch (const common_json_error & e) {
        LOG_ERR("%s: JSON error: %s\n", __func__, e.what());
    } catch (const std::exception & e) {
        LOG_ERR("%s: error: %s\n", __func__, e.what());
    }
    return files;
}

} // namespace hf_cache
