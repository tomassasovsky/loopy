// Forwarder translation unit for the CocoaPods (macOS/iOS) build.
//
// CocoaPods cannot reference source files outside the podspec directory, so the
// shared plugin include-probe under ../../src/host is pulled in via this
// relative #include. The VST3/CLAP include roots are added through
// HEADER_SEARCH_PATHS and LOOPY_ENABLE_PLUGINS through GCC_PREPROCESSOR_DEFINITIONS
// in loopy_engine.podspec — so the probe body is active on macOS.
#include "../../src/host/plugin_probe.cpp"
