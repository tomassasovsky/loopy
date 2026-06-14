// Forwarder translation unit — see engine.c for why this indirection exists.
// Compiles the CoreMIDI capture backend into the plugin framework. The Linux
// (ALSA) and Windows (WinMM) backends are not forwarded: le_midi_select_backend
// references only le_midi_apple_backend on Apple, so they are never linked here.
#include "../../src/midi_backend_apple.c"
