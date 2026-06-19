// Forwarder translation unit for the Swift Package Manager (macOS) build.
//
// SPM only compiles sources inside the package directory, so the shared C
// engine under <plugin>/src is pulled in via this relative #include. Headers
// referenced by the included source resolve relative to its real location
// (../src) plus the headerSearchPath entries declared in Package.swift.
#include "../../../../src/core/engine.c"
