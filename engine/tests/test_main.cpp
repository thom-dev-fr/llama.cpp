#include "test_util.hpp"

#include <cstdio>

int g_failures = 0;
int g_total    = 0;

extern void run_params_translator_tests();
extern void run_engine_lifecycle_tests();
extern void run_inflight_registry_tests();
extern void run_chat_route_adapter_tests();

int main() {
    run_params_translator_tests();
    run_engine_lifecycle_tests();
    run_inflight_registry_tests();
    run_chat_route_adapter_tests();

    std::printf("\n===== %d / %d passed =====\n", g_total - g_failures, g_total);
    return g_failures == 0 ? 0 : 1;
}
