#pragma once

#include "json-schema.h"
#include "json.h"

#include <functional>
#include <string>

std::string json_schema_to_grammar(const common_json & schema, bool force_gbnf = false);
std::string json_schema_to_grammar(const common_chat_schema_document & schema);

// Throws std::invalid_argument when the grammar of the schema would approximate it, e.g. a pattern outside
// the supported regex subset that json_schema_to_grammar replaces by any string with a warning.
void json_schema_check_strict(const common_json & schema);

struct common_grammar_builder {
    std::function<std::string(const std::string &, const std::string &)>    add_rule;
    std::function<std::string(const std::string &, const common_chat_schema &)> add_schema;
};

struct common_grammar_options {
    bool dotall = false;
};

std::string gbnf_format_literal(const std::string & literal);

std::string build_grammar(const std::function<void(const common_grammar_builder &)> & cb, const common_grammar_options & options = {});
