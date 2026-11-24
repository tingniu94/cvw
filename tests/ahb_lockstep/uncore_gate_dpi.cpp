// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Top-independent implementation required by the original RAM/ROM DPI import.
#include <cstdlib>
extern "C" const char* getenvval(const char* name) {
    const char* value = std::getenv(name);
    return value ? value : "";
}
