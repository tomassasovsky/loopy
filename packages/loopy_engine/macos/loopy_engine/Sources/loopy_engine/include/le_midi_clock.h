// Forwarder header for the Swift Package Manager (macOS) build.
//
// engine_private.h includes "le_midi_clock.h" (C1, D15), but the real header
// lives in ../src/midi/ — outside this SPM package, where SPM refuses to add a
// header search path. SPM does add this target's include/ directory to the
// search path, so this forwarder (found after the relative-to-source lookup
// fails, same as this directory's miniaudio.h forwarder) redirects to the real
// header at the plugin root.
#include "../../../../../src/midi/le_midi_clock.h"
