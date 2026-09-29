#pragma once

#include "server-common.h"

// SSE wire encoding belongs to the HTTP consumer, not to inference.
std::string format_oai_sse(const json & data);
std::string format_oai_resp_sse(const json & data);
std::string format_anthropic_sse(const json & data);

std::string format_metrics(const json & data);
