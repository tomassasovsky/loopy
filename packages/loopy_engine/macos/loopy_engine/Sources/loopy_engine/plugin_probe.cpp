// Forwarder translation unit for the Swift Package Manager (macOS) build.
//
// SPM only compiles sources inside the package directory, so the shared plugin
// include-probe under <plugin>/src/host is pulled in via this relative
// #include. The VST3/CLAP include roots are added as header search paths in
// Package.swift (cxxSettings), and LOOPY_ENABLE_PLUGINS is defined there too —
// so the probe body is active on macOS.
#include "../../../../src/host/plugin_probe.cpp"
