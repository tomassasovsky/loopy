// Header forwarder for the SPM (macOS) build: SPM adds include/ to the header
// search path but cannot point outside the package, so a cross-folder engine
// header a forwarded source includes by name is surfaced here.
//
// Needed because le_midi_clock.c (src/midi/, C1) includes "tempo_grid.h",
// which lives in src/core/ — a different directory, so the relative-to-source
// lookup that resolves same-directory includes (e.g. le_midi_clock.c's own
// "le_midi_clock.h") does not find it.
#include "../../../../../src/core/tempo_grid.h"
