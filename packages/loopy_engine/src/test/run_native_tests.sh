#!/usr/bin/env bash
# run_native_tests.sh — build + run the native engine and MIDI unit tests.
#
# The portable engine has no audio-device dependency in these tests, so they
# compile and run on any of the three desktop OSes with the host toolchain.
# This is the gate for any refactor of the engine sources: "ALL PASSED" twice.
#
# The engine source list MUST match src/CMakeLists.txt's add_library list
# (minus the MIDI TUs, which the engine test does not link). Keep them in sync.
set -euo pipefail
cd "$(dirname "$0")/../.."   # src/test -> packages/loopy_engine

OUT="${TMPDIR:-/tmp}"
CC="${CC:-gcc}"
STD="-std=c11 -I src -I src/miniaudio"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ENGINE_LIBS="-lole32 -lwinmm -lm"; MIDI_LIBS="-lwinmm" ;;
  Darwin) ENGINE_LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lm"
          MIDI_LIBS="-framework CoreMIDI -framework CoreFoundation" ;;
  *) ENGINE_LIBS="-lpthread -lm"; MIDI_LIBS="-lasound -lpthread" ;;
esac

# Glob every engine TU (engine.c plus the incremental S1 split: engine_*.c, the
# per-OS seams, and the miniaudio backend) so this list tracks the split with no
# edits. Pairs with the fixed primitives. Mirrors src/CMakeLists.txt's library
# sources (minus the MIDI TUs, which the engine test does not link).
ENGINE_SRC="src/engine*.c src/lockfree_ring.c src/loop_clock.c src/miniaudio_impl.c"

echo "== building engine tests =="
# shellcheck disable=SC2086
$CC $STD src/test/test_engine_core.c $ENGINE_SRC $ENGINE_LIBS \
  -o "$OUT/loopy_core_tests.exe"
"$OUT/loopy_core_tests.exe"

echo "== building midi tests =="
# shellcheck disable=SC2086
$CC $STD src/test/test_midi_core.c src/midi.c src/midi_backend_linux.c \
  src/midi_backend_apple.c src/midi_backend_windows.c $MIDI_LIBS \
  -o "$OUT/loopy_midi_tests.exe"
"$OUT/loopy_midi_tests.exe"
