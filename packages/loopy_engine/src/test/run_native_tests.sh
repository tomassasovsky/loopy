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
# gnu11 (not strict c11) matches the shipped build (CMake C_STANDARD 11 with
# extensions on) and exposes the POSIX symbols the Linux MIDI backend needs
# (clock_gettime / CLOCK_MONOTONIC; strict c11 also triggers ALSA's struct
# timespec redefinition). Include path mirrors src/CMakeLists.txt: every src
# subdir holding headers, so the sources' flat `#include "x.h"` resolves.
STD="-std=gnu11 -I src/core -I src/midi -I src/asio -I src/miniaudio"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ENGINE_LIBS="-lole32 -lwinmm -lm"; MIDI_LIBS="-lwinmm" ;;
  Darwin) ENGINE_LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lm"
          MIDI_LIBS="-framework CoreMIDI -framework CoreFoundation" ;;
  *) ENGINE_LIBS="-lpthread -lm -ldl"; MIDI_LIBS="-lasound -lpthread" ;;  # Linux: miniaudio dlopen()s its backends
esac

# Glob every engine TU (the core/ TUs incl. the miniaudio backend, the platform/
# seams, and the miniaudio impl) so this tracks the split with no edits. Pairs
# with the core primitives. Mirrors src/CMakeLists.txt's library sources (minus
# the MIDI TUs, which the engine test does not link).
ENGINE_SRC="src/core/engine*.c src/core/lockfree_ring.c src/core/loop_clock.c \
  src/platform/engine_*.c src/miniaudio/miniaudio_impl.c"

echo "== building engine tests =="
# shellcheck disable=SC2086
$CC $STD src/test/test_engine_core.c $ENGINE_SRC $ENGINE_LIBS \
  -o "$OUT/loopy_core_tests.exe"
"$OUT/loopy_core_tests.exe"

echo "== building midi tests =="
# shellcheck disable=SC2086
$CC $STD src/test/test_midi_core.c src/midi/midi.c src/midi/midi_backend_linux.c \
  src/midi/midi_backend_apple.c src/midi/midi_backend_windows.c $MIDI_LIBS \
  -o "$OUT/loopy_midi_tests.exe"
"$OUT/loopy_midi_tests.exe"

# --- Plugin scan tests (macOS only) ----------------------------------------
# Plugin hosting is macOS-first (LOOPY_ENABLE_PLUGINS). This compiles the scan
# ABI + backends against the vendored VST3/CLAP SDKs and exercises the
# per-candidate failed-entry guard with a controlled fixture (no real plugin
# install needed). Skipped on Windows/Linux until the ports (parts 8–9).
if [ "$(uname -s)" = "Darwin" ]; then
  echo "== building plugin scan tests =="
  CXX="${CXX:-clang++}"
  PLUGIN_INC="-Ithird_party/vst3sdk -Ithird_party/clap/include -Isrc/core -Isrc/host"
  # shellcheck disable=SC2086
  $CXX -std=c++17 -DLOOPY_ENABLE_PLUGINS $PLUGIN_INC \
    src/test/test_plugin_scan.cpp \
    src/host/plugin_scan.cpp src/host/scan_vst3.cpp src/host/scan_clap.cpp \
    third_party/vst3sdk/pluginterfaces/base/coreiids.cpp \
    -framework CoreFoundation \
    -o "$OUT/loopy_plugin_scan_tests.exe"
  "$OUT/loopy_plugin_scan_tests.exe"
fi
