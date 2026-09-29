#include "engine-operations.h"
#include "engine-runtime.h"
#include "server-chat.h"
#include "server-schema.h"

namespace llama_engine { namespace detail {
using ::json;

json assemble_completions(json arr, task_response_type format) {
    if (arr.size() == 1) { return std::move(arr[0]); }
    if (format == TASK_RESPONSE_TYPE_OAI_CHAT || format == TASK_RESPONSE_TYPE_OAI_CMPL) {
        for (size_t i = 1; i < arr.size(); ++i) {
            arr[0]["choices"].push_back(std::move(arr[i]["choices"][0]));
        }
        return std::move(arr[0]);
    }
    return arr;
}
json engine_model_info(const server_context_meta & meta) {
    // Only owned metadata is read here, including while the model is sleeping.

    return {
        {"id",       meta.model_name},
        {"aliases",  meta.model_aliases},
        {"tags",     meta.model_tags},
        {"object",   "model"},
        {"created",  std::time(0)},
        {"owned_by", "llamacpp"},
        {"meta",     {
            {"vocab_type",  meta.model_vocab_type},
            {"n_vocab",     meta.model_vocab_n_tokens},
            {"n_ctx",       meta.slot_n_ctx},
            {"n_ctx_train", meta.model_n_ctx_train},
            {"n_embd",      meta.model_n_embd_inp},
            {"n_params",    meta.model_n_params},
            {"size",        meta.model_size},
            {"ftype",       meta.model_ftype},
        }},
    };
}

json engine_models(const server_context_meta & meta) {
    // Only owned metadata is read here, including while the model is sleeping.

    return json{
        {"models", json::array({
            {
                {"name",  meta.model_name},
                {"model", meta.model_name},
                {"modified_at", ""},
                {"size", ""},
                {"digest", ""}, // dummy value, llama.cpp does not support managing model file's hash
                {"type", "model"},
                {"description", ""},
                {"tags", json::array({""})},
                {"capabilities", meta.has_mtmd ? json::array({"completion","multimodal"}) : json::array({"completion"})},
                {"parameters", ""},
                {"details", {
                    {"parent_model", ""},
                    {"format", "gguf"},
                    {"family", ""},
                    {"families", json::array({""})},
                    {"parameter_size", ""},
                    {"quantization_level", ""}
                }}
            }
        })},
        {"object", "list"},
        {"data", json::array({
            engine_model_info(meta),
        })}
    };
}

json engine_properties(const server_context_meta & meta, const common_params & params, bool is_sleeping) {
    // Only owned metadata is read here, including while the model is sleeping.

    task_params tparams;
    tparams.sampling = params.sampling;
    json default_generation_settings_for_props = json {
        { "params", tparams.to_json(true) },
        { "n_ctx",  meta.slot_n_ctx },
    };

    std::string tmpl_default = common_chat_templates_source(meta.chat_params.tmpls.get(), "");
    std::string tmpl_tools   = common_chat_templates_source(meta.chat_params.tmpls.get(), "tool_use");

    json props = {
        { "default_generation_settings", default_generation_settings_for_props },
        { "total_slots",                 params.n_parallel },
        { "model_alias",                 meta.model_name },
        { "model_ftype",                 meta.model_ftype },
        { "model_path",                  meta.model_path },
        { "modalities",                  json {
            {"vision", meta.has_inp_image},
            {"video",  meta.has_inp_video},
            {"audio",  meta.has_inp_audio},
        } },
        { "media_marker",                get_media_marker() },
        { "endpoint_slots",              params.endpoint_slots },
        { "endpoint_props",              params.endpoint_props },
        { "endpoint_metrics",            params.endpoint_metrics },
        { "ui",                          params.ui },
        { "ui_settings",                 meta.json_ui_settings },
        { "chat_template",               tmpl_default },
        { "chat_template_caps",          meta.chat_template_caps },
        { "bos_token",                   meta.bos_token_str },
        { "eos_token",                   meta.eos_token_str },
        { "build_info",                  meta.build_info },
        { "is_sleeping",                 is_sleeping },
        { "cors_proxy_enabled",          params.ui_mcp_proxy },
    };
    if (params.use_jinja) {
        if (!tmpl_tools.empty()) {
            props["chat_template_tool_use"] = tmpl_tools;
        }
    }

    return props;
}

void validate_operation_support(const server_context_meta & meta, const common_params & params, operation op) {
    switch (op) {
        case operation::embeddings:
        case operation::embeddings_openai:
            if (!params.embedding) {
                throw operation_error(format_error_response("This server does not support embeddings. Start it with `--embeddings`", ERROR_TYPE_NOT_SUPPORTED));
            }
            if (op == operation::embeddings_openai && meta.pooling_type == LLAMA_POOLING_TYPE_NONE) {
                throw operation_error(format_error_response("Pooling type 'none' is not OAI compatible. Please use a different pooling type", ERROR_TYPE_INVALID_REQUEST));
            }
            break;
        case operation::rerank:
            if (!params.embedding || params.pooling_type != LLAMA_POOLING_TYPE_RANK) {
                throw operation_error(format_error_response("This server does not support reranking. Start it with `--reranking`", ERROR_TYPE_NOT_SUPPORTED));
            }
            break;
        case operation::transcription:
            if (!meta.has_mtmd || !meta.chat_params.allow_audio) {
                throw operation_error(format_error_response("The current model does not support audio input.", ERROR_TYPE_NOT_SUPPORTED));
            }
            break;
        case operation::infill: {
            std::string err;
            if (meta.fim_pre_token == LLAMA_TOKEN_NULL) { err += "prefix token is missing. "; }
            if (meta.fim_sub_token == LLAMA_TOKEN_NULL) { err += "suffix token is missing. "; }
            if (meta.fim_mid_token == LLAMA_TOKEN_NULL) { err += "middle token is missing. "; }
            if (!err.empty()) {
                throw operation_error(format_error_response(string_format("Infill is not supported by this model: %s", err.c_str()), ERROR_TYPE_NOT_SUPPORTED));
            }
            break;
        }
        default: break;
    }
}

prepared_operation prepare_operation(server_context & context, operation op, json body,
                                     const std::vector<attachment> & attachments, size_t max_tasks) {
    const auto & params = context.parameters();
    const auto meta = context.get_meta();
    validate_operation_support(meta, params, op);
    prepared_operation out;
    std::vector<raw_buffer> files;
    auto one_task = [&](server_task_type type) -> server_task & {
        out.tasks.emplace_back(type);
        out.tasks.back().id = context.tasks().get_new_id();
        return out.tasks.back();
    };
    std::map<std::string, raw_buffer> named_files;
    for (const auto & file : attachments) {
        if (file.name.empty() || !named_files.emplace(file.name, file.bytes).second) {
            throw std::invalid_argument("Attachment names must be non-empty and unique");
        }
    }
    if (!attachments.empty() && op != operation::transcription && op != operation::chat &&
        op != operation::responses && op != operation::messages && op != operation::chat_tokens &&
        op != operation::response_tokens && op != operation::message_tokens && op != operation::apply_template) {
        throw std::invalid_argument("Named attachments are not supported by this operation");
    }
    switch (op) {
        case operation::properties_update: out.immediate = {{"success", true}}; return out;
        case operation::properties:
        case operation::models: {
            if (context.tasks().is_sleeping()) {
                std::lock_guard<std::mutex> lock(context.runtime->snapshot_mutex);
                out.immediate = op == operation::properties ? context.runtime->sleep_properties : context.runtime->sleep_models;
            } else {
                out.immediate = op == operation::properties ? engine_properties(meta, params, false) : engine_models(meta);
            }
            return out;
        }
        case operation::metrics: {
            auto & task = one_task(SERVER_TASK_TYPE_METRICS);
            task.metrics_reset_bucket = json_value(body, "reset", true);
            out.priority = true;
            return out;
        }
        case operation::slots: one_task(SERVER_TASK_TYPE_SLOT_GET); out.priority = true; return out;
        case operation::lora_list: one_task(SERVER_TASK_TYPE_GET_LORA); return out;
        case operation::lora_apply: {
            if (!body.is_array()) { throw operation_error(format_error_response("Request body must be an array", ERROR_TYPE_INVALID_REQUEST)); }
            one_task(SERVER_TASK_TYPE_SET_LORA).set_lora = parse_lora_request(body);
            return out;
        }
        case operation::slot_save:
        case operation::slot_restore:
        case operation::slot_erase: {
            if (params.slot_save_path.empty()) {
                throw operation_error(format_error_response("This server does not support slots action. Start it with `--slot-save-path`", ERROR_TYPE_NOT_SUPPORTED));
            }
            auto & task = one_task(op == operation::slot_save ? SERVER_TASK_TYPE_SLOT_SAVE :
                                  op == operation::slot_restore ? SERVER_TASK_TYPE_SLOT_RESTORE : SERVER_TASK_TYPE_SLOT_ERASE);
            task.slot_action.id_slot = body.at("id_slot").get<int>();
            if (op != operation::slot_erase) {
                std::string filename = body.at("filename");
                if (!fs_validate_filename(filename)) { throw operation_error(format_error_response("Invalid filename", ERROR_TYPE_INVALID_REQUEST)); }
                task.slot_action.filename = filename;
                task.slot_action.filepath = params.slot_save_path + filename;
            }
            return out;
        }
        case operation::control: {
            const std::string id = json_value(body, "id", std::string());
            const std::string action = json_value(body, "action", std::string());
            if (id.empty()) { throw operation_error(format_error_response("missing completion id", ERROR_TYPE_INVALID_REQUEST)); }
            if (action != "reasoning_end") { throw operation_error(format_error_response("unknown control action", ERROR_TYPE_INVALID_REQUEST)); }
            auto & task = one_task(SERVER_TASK_TYPE_CONTROL);
            task.params.control_cmpl_id = id;
            task.params.control_action = action;
            return out;
        }
        case operation::tokenize: {
            json tokens_response = json::array();
            if (body.count("content") != 0) {
                const bool add_special = json_value(body, "add_special", false);
                const bool parse_special = json_value(body, "parse_special", true);
                const bool with_pieces = json_value(body, "with_pieces", false);

                llama_tokens tokens = tokenize_mixed(context.vocabulary(), body.at("content"), add_special, parse_special);

                if (with_pieces) {
                    for (const auto& token : tokens) {
                        std::string piece = common_token_to_piece(context.vocabulary(), token);
                        json piece_json;

                        // Check if the piece is valid UTF-8
                        if (is_valid_utf8(piece)) {
                            piece_json = piece;
                        } else {
                            // If not valid UTF-8, store as array of byte values
                            piece_json = json::array();
                            for (unsigned char c : piece) {
                                piece_json.push_back(static_cast<int>(c));
                            }
                        }

                        tokens_response.push_back({
                            {"id", token},
                            {"piece", piece_json}
                        });
                    }
                } else {
                    tokens_response = tokens;
                }
            }

            out.immediate = json{{"tokens", std::move(tokens_response)}};
            return out;
        }
        case operation::detokenize: {
            std::string content;
            if (body.count("tokens") != 0) {
                const llama_tokens tokens = body.at("tokens").get<llama_tokens>();
                content = tokens_to_str(context.vocabulary(), tokens);
            }

            out.immediate = json{{"content", std::move(content)}};
            return out;
        }
        case operation::embeddings:
        case operation::embeddings_openai: {
            auto res_type = op == operation::embeddings_openai ? TASK_RESPONSE_TYPE_OAI_EMBD : TASK_RESPONSE_TYPE_NONE;
            // for the shape of input/content, see tokenize_input_prompts()
            json prompt;
            if (body.count("input") != 0) {
                prompt = body.at("input");
            } else if (body.contains("content")) {
                res_type = TASK_RESPONSE_TYPE_NONE; // "content" field is not OAI compatible
                prompt = body.at("content");
            } else {
                throw operation_error(format_error_response("\"input\" or \"content\" must be provided", ERROR_TYPE_INVALID_REQUEST));
            }

            bool use_base64 = false;
            if (body.count("encoding_format") != 0) {
                const std::string & format = body.at("encoding_format");
                if (format == "base64") {
                    use_base64 = true;
                } else if (format != "float") {
                    throw operation_error(format_error_response("The format to return the embeddings in. Can be either float or base64", ERROR_TYPE_INVALID_REQUEST));
                }
            }

            // same shapes as tokenize_input_prompts(), plus OAI content: { "content": [ { "type": "text"|"image_url"|"input_audio"|"input_video", ... } ] }
            auto tokenize_entry = [&](const json & p) {
                if (p.is_object() && p.contains("content")) {
                    return tokenize_oai_content_array(context.vocabulary(), context.multimodal(), meta.chat_params, p.at("content"), true, true, context.media_options());
                }
                return tokenize_input_subprompt(context.vocabulary(), context.multimodal(), p, true, true, context.media_options());
            };

            std::vector<server_tokens> tokenized_prompts;
            if (prompt.is_array() && !json_is_array_and_contains_numbers(prompt)) {
                for (const auto & p : prompt) {
                    tokenized_prompts.push_back(tokenize_entry(p));
                }
            } else {
                tokenized_prompts.push_back(tokenize_entry(prompt));
            }
            if (tokenized_prompts.empty()) {
                throw operation_error(format_error_response("\"input\" must not be empty", ERROR_TYPE_INVALID_REQUEST));
            }

            for (const auto & tokens : tokenized_prompts) {
                // this check is necessary for models that do not add BOS token to the input
                if (tokens.empty()) {
                    throw operation_error(format_error_response("Input content cannot be empty", ERROR_TYPE_INVALID_REQUEST));
                }
            }

            int embd_normalize = params.embd_normalize;
            if (body.count("embd_normalize") != 0) {
                embd_normalize = body.at("embd_normalize").get<int>();
                if (meta.pooling_type == LLAMA_POOLING_TYPE_NONE) {
                    SRV_DBG("embd_normalize is not supported by pooling type %d, ignoring it\n", meta.pooling_type);
                }
            }

            if (tokenized_prompts.size() > max_tasks) { throw std::length_error("Engine task limit exceeded"); }
            // Prepare tasks; the runtime owns admission and queueing.
            {
                std::vector<server_task> tasks;
                for (size_t i = 0; i < tokenized_prompts.size(); i++) {
                    server_task task = server_task(SERVER_TASK_TYPE_EMBEDDING);

                    task.id     = context.tasks().get_new_id();
                    task.tokens = std::move(tokenized_prompts[i]);

                    // OAI-compat
                    task.params.res_type = res_type;
                    task.params.embd_normalize = embd_normalize;

                    tasks.push_back(std::move(task));
                }
                out.tasks = std::move(tasks);
            }

            out.assemble = [body, name = meta.model_name, res_type, use_base64](json results) {
                return res_type == TASK_RESPONSE_TYPE_OAI_EMBD
                    ? format_embeddings_response_oaicompat(body, name, results, use_base64) : results;
            };
            return out;
        }
        case operation::rerank: {
            // if true, use TEI API format, otherwise use Jina API format
            // Jina: https://jina.ai/reranker/
            // TEI: https://huggingface.github.io/text-embeddings-inference/#/Text%20Embeddings%20Inference/rerank
            bool is_tei_format = body.contains("texts");

            json query;
            if (body.count("query") == 1) {
                query = body.at("query");
                if (!query.is_string()) {
                    throw operation_error(format_error_response("\"query\" must be a string", ERROR_TYPE_INVALID_REQUEST));
                }
            } else {
                throw operation_error(format_error_response("\"query\" must be provided", ERROR_TYPE_INVALID_REQUEST));
            }

            std::vector<std::string> documents = json_value(body, "documents",
                                                 json_value(body, "texts", std::vector<std::string>()));
            if (documents.empty()) {
                throw operation_error(format_error_response("\"documents\" must be a non-empty string array", ERROR_TYPE_INVALID_REQUEST));
            }

            if (documents.size() > max_tasks) { throw std::length_error("Engine task limit exceeded"); }
            int top_n = json_value(body, "top_n", (int)documents.size());

            // Prepare tasks; the runtime owns admission and queueing.
            {
                std::vector<server_task> tasks;
                tasks.reserve(documents.size());
                for (size_t i = 0; i < documents.size(); i++) {
                    auto tmp = format_prompt_rerank(context.model(), context.vocabulary(), context.multimodal(), query, documents[i], context.media_options());
                    server_task task = server_task(SERVER_TASK_TYPE_RERANK);
                    task.id     = context.tasks().get_new_id();
                    task.tokens = std::move(tmp);
                    tasks.push_back(std::move(task));
                }
                out.tasks = std::move(tasks);
            }

            out.assemble = [body, name = meta.model_name, is_tei_format, documents, top_n](json results) mutable {
                return format_response_rerank(body, name, results, is_tei_format, documents, top_n);
            };
            return out;
        }
        default: break;
    }
    server_task_type type = SERVER_TASK_TYPE_COMPLETION;
    switch (op) {
        case operation::completion: break;
        case operation::completions: out.format = TASK_RESPONSE_TYPE_OAI_CMPL; break;
        case operation::responses:
        case operation::response_tokens:
            body = server_chat_convert_responses_to_chatcmpl(body);
            out.format = TASK_RESPONSE_TYPE_OAI_RESP;
            break;
        case operation::messages:
        case operation::message_tokens:
            body = server_chat_convert_anthropic_to_oai(body);
            out.format = TASK_RESPONSE_TYPE_ANTHROPIC;
            break;
        case operation::chat:
        case operation::chat_tokens:
        case operation::apply_template: out.format = TASK_RESPONSE_TYPE_OAI_CHAT; break;
        case operation::transcription: {
            std::map<std::string, uploaded_file> uploaded;
            for (const auto & file : attachments) { uploaded[file.name].data = file.bytes; }
            body = convert_transcriptions_to_chatcmpl(body, meta.chat_params.tmpls.get(), uploaded, files);
            out.format = TASK_RESPONSE_TYPE_OAI_ASR;
            break;
        }
        case operation::infill: {
            // validate input
            json & data = body;
            if (data.contains("input_extra") && !data.at("input_extra").is_array()) {
                // input_extra is optional
                throw operation_error(format_error_response("\"input_extra\" must be an array of {\"filename\": string, \"text\": string}", ERROR_TYPE_INVALID_REQUEST));
            }

            json input_extra = json_value(data, "input_extra", json::array());
            for (const auto & chunk : input_extra) {
                // { "text": string, "filename": string }
                if (!chunk.contains("text") || !chunk.at("text").is_string()) {
                    throw operation_error(format_error_response("extra_context chunk must contain a \"text\" field with a string value", ERROR_TYPE_INVALID_REQUEST));
                }
                // filename is optional
                if (chunk.contains("filename") && !chunk.at("filename").is_string()) {
                    throw operation_error(format_error_response("extra_context chunk's \"filename\" field must be a string", ERROR_TYPE_INVALID_REQUEST));
                }
            }
            data["input_extra"] = input_extra; // default to empty array if it's not exist

            std::string prompt = json_value(data, "prompt", std::string());
            std::vector<server_tokens> tokenized_prompts = tokenize_input_prompts(context.vocabulary(), context.multimodal(), prompt, false, true, context.media_options());
            SRV_DBG("creating infill tasks, n_prompts = %d\n", (int) tokenized_prompts.size());
            data["prompt"] = format_prompt_infill(
                context.vocabulary(),
                data.at("input_prefix"),
                data.at("input_suffix"),
                data.at("input_extra"),
                params.n_batch,
                params.n_predict,
                meta.slot_n_ctx,
                params.spm_infill,
                tokenized_prompts[0].get_tokens() // TODO: this could maybe be multimodal.
            );

            type = SERVER_TASK_TYPE_INFILL;
            break;
        }
        default: throw std::invalid_argument("Unknown engine operation");
    }
    if (out.format == TASK_RESPONSE_TYPE_OAI_CHAT || out.format == TASK_RESPONSE_TYPE_OAI_RESP ||
        out.format == TASK_RESPONSE_TYPE_ANTHROPIC || out.format == TASK_RESPONSE_TYPE_OAI_ASR) {
        body = oaicompat_chat_params_parse(body, meta.chat_params, files, named_files);
    }
    if (op == operation::apply_template) {
        out.immediate = {{"prompt", std::move(body.at("prompt"))}};
        return out;
    }
    if (op == operation::chat_tokens || op == operation::response_tokens || op == operation::message_tokens) {
        const auto & prompt = body.at("prompt");
        size_t count;
        if (context.multimodal()) {
            if (!prompt.is_string()) { throw std::runtime_error("for mtmd, input prompt must be a string."); }
            count = process_mtmd_prompt(context.multimodal(), prompt.get<std::string>(), files, context.media_options(), true).size();
        } else {
            count = tokenize_mixed(context.vocabulary(), prompt, true, true).size();
        }
        out.immediate = {{"input_tokens", static_cast<int64_t>(count)}};
        if (op != operation::message_tokens) { out.immediate["object"] = "response.input_tokens"; }
        return out;
    }
    try {
        out.tasks = context.prepare_completion(body, type, out.format, files, max_tasks);
    } catch (const std::length_error &) {
        throw;
    } catch (const std::exception & error) {
        throw operation_error(format_error_response(error.what(), ERROR_TYPE_INVALID_REQUEST));
    }
    out.assemble = [format = out.format](json results) { return assemble_completions(std::move(results), format); };
    return out;
}
} }
