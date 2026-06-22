// Forwarder translation unit for the CocoaPods (macOS/iOS) build.
//
// CocoaPods cannot reference source files outside the podspec directory, so the
// shared C engine under ../../src is pulled in via these per-file forwarders
// (one per native TU the macOS build needs). Headers referenced by the included
// source resolve through HEADER_SEARCH_PATHS (../src/core, ../src/midi,
// ../src/miniaudio) declared in the podspec.
#include "../../src/core/engine_miniaudio.c"
