// The original memory models import getenvval. This smoke test has its own
// Verilator top, so use its generated DPI declaration rather than Vtestbench's.
#include <cstdlib>
#include "Vno_bus_tb__Dpi.h"

const char *getenvval(const char *name) {
    const char *value = std::getenv(name);
    return value ? value : "";
}
