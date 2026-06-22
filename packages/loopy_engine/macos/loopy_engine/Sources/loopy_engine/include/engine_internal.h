// Header forwarder for the SPM (macOS) build: SPM adds include/ to the header
// search path but cannot point outside the package, so a cross-folder engine
// header a forwarded source includes by name is surfaced here.
#include "../../../../../src/core/engine_internal.h"
