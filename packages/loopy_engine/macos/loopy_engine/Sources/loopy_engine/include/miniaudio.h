// Forwarder header for the Swift Package Manager (macOS) build.
//
// The shared engine sources include "miniaudio.h", but the real header lives in
// ../src/miniaudio/ — outside this SPM package, where SPM refuses to add a
// header search path. SPM does add this target's include/ directory to the
// search path, so this forwarder (found after the relative-to-source lookup
// fails) redirects to the vendored header at the plugin root.
#include "../../../../../src/miniaudio/miniaudio.h"
