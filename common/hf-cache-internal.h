#pragma once

// Shared validation and path construction for the local cache and the optional
// HF network client. Not an interface for applications embedding inference.
#include <filesystem>
#include <string>

namespace hf_cache {
namespace detail {

std::filesystem::path get_repo_path(const std::string & repo_id);
bool is_valid_repo_id(const std::string & repo_id);
bool is_valid_commit(const std::string & hash);
bool is_valid_oid(const std::string & oid);
bool is_alphanum(char c);

} // namespace detail
} // namespace hf_cache
