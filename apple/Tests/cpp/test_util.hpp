#pragma once

#include <cstdio>
#include <sstream>
#include <string>

extern int g_failures;
extern int g_total;

#define EXPECT(cond)                                                                        \
    do {                                                                                    \
        g_total++;                                                                          \
        if (!(cond)) {                                                                      \
            g_failures++;                                                                   \
            std::fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond);           \
        }                                                                                   \
    } while (0)

#define EXPECT_EQ(a, b)                                                                     \
    do {                                                                                    \
        g_total++;                                                                          \
        auto _va = (a);                                                                     \
        auto _vb = (b);                                                                     \
        if (!(_va == _vb)) {                                                                \
            g_failures++;                                                                   \
            std::stringstream _ss;                                                          \
            _ss << _va << " != " << _vb;                                                    \
            std::fprintf(stderr, "FAIL: %s:%d: %s (%s)\n",                                  \
                         __FILE__, __LINE__, #a " == " #b, _ss.str().c_str());              \
        }                                                                                   \
    } while (0)

#define EXPECT_THROWS(expr, exc_type)                                                       \
    do {                                                                                    \
        g_total++;                                                                          \
        bool _caught = false;                                                               \
        try { (void)(expr); }                                                               \
        catch (const exc_type &) { _caught = true; }                                        \
        catch (...) { _caught = false; }                                                    \
        if (!_caught) {                                                                     \
            g_failures++;                                                                   \
            std::fprintf(stderr, "FAIL: %s:%d: expected %s to throw %s\n",                  \
                         __FILE__, __LINE__, #expr, #exc_type);                             \
        }                                                                                   \
    } while (0)

#define CASE(name)                                                                          \
    std::fprintf(stderr, "  * %s\n", name)
