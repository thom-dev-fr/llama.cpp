#pragma once

#include "llama_engine.h"

#include <string>

namespace llama_engine {

// Read GGUF metadata from `model_path` (and optionally `mmproj_path`) and
// fill `out` with the model's intrinsic capabilities + display metadata.
//
// Pure with respect to the engine: does not touch llama_backend, does not
// allocate ggml contexts, does not load tensor data. Works without a
// llama_engine_t and without a loaded model.
//
// Soft errors (missing keys, unparseable chat template, mmproj without
// clip.has_*_encoder) are absorbed silently \u2014 the corresponding fields
// stay at their zero/NULL value. Hard errors (file not found, invalid GGUF
// header) are returned via the status code, and `error` is populated with
// a human-readable message suitable for forwarding to the user.
//
// Caller owns the strings inside `out` and must release them with
// llama_engine_free_model_info() (or by hand). On non-OK return, `out`
// is fully zero-initialised \u2014 nothing to free.
llama_engine_status probe_model_info(const char *              model_path,
                                     const char *              mmproj_path,
                                     llama_engine_model_info & out,
                                     std::string &             error);

} // namespace llama_engine
