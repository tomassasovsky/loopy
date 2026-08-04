// Forwarder translation unit for the Swift Package Manager (macOS) build.
//
// SPM only compiles sources inside the package directory, so the shared C engine
// under <plugin>/src is pulled in via this relative #include. Headers the
// included source needs resolve relative to its real location (src/core) plus
// the cross-folder forwarders in include/ (SPM adds include/ to the search path;
// it cannot point outside the package).
#include "../../../../src/core/engine_snapshot.c"
