// Forwarder translation unit for the CocoaPods (macOS/iOS) build.
//
// CocoaPods does not support `source_files` paths outside the podspec
// directory, so the shared C sources under ../../src cannot be referenced
// directly. This file (inside the pod's Classes/ dir) relatively #includes the
// real implementation so it is compiled into the plugin framework. Header
// resolution for the included file falls back to HEADER_SEARCH_PATHS
// (../src, ../src/miniaudio) declared in the podspec.
#include "../../src/engine_apple.c"
