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
# Extra compile/link flags, e.g. EXTRA_CFLAGS="-fsanitize=address -g" for the
# CI ASAN job (compile and link happen in one $CC call, so this covers both).
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"
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
  src/core/audio_ring.c src/core/perf_drain.c src/core/perf_log_ring.c src/core/layer_staging_ring.c src/core/json_read.c src/core/perf_render.c src/core/plugin_disabled.c \
  src/platform/engine_*.c src/miniaudio/miniaudio_impl.c"

echo "== building engine tests =="
# shellcheck disable=SC2086
$CC $STD $EXTRA_CFLAGS src/test/test_engine_core.c $ENGINE_SRC $ENGINE_LIBS \
  -o "$OUT/loopy_core_tests.exe"
"$OUT/loopy_core_tests.exe"

echo "== building midi tests =="
# shellcheck disable=SC2086
$CC $STD $EXTRA_CFLAGS src/test/test_midi_core.c src/midi/midi.c src/midi/midi_backend_linux.c \
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

  # Slot lifecycle / adapter / sanitize, driven end-to-end through the real
  # fx_apply_chain (engine_fx.c — the self-contained DSP island) with a stub
  # host. C engine TUs and C++ host TUs are compiled separately, then linked.
  echo "== building plugin slot tests =="
  P3="$OUT/loopy_p3_obj"
  mkdir -p "$P3"
  CENGINE_INC="-Isrc/core -Isrc/midi -Isrc/miniaudio -Isrc/host"
  clang -std=gnu11 -DLOOPY_ENABLE_PLUGINS $CENGINE_INC \
    -c src/test/test_plugin_slot.c -o "$P3/test.o"
  clang -std=gnu11 -DLOOPY_ENABLE_PLUGINS $CENGINE_INC \
    -c src/core/engine_fx.c -o "$P3/engine_fx.o"
  clang -std=gnu11 -DLOOPY_ENABLE_PLUGINS $CENGINE_INC \
    -c src/core/engine_plugin.c -o "$P3/engine_plugin.o"
  # shellcheck disable=SC2086
  for cxx in slot host_clap host_vst3 plugin_scan scan_vst3 scan_clap; do
    $CXX -std=c++17 -DLOOPY_ENABLE_PLUGINS $PLUGIN_INC \
      -c "src/host/$cxx.cpp" -o "$P3/$cxx.o"
  done
  # The host-owned editor NSWindow (ObjC++, part 6) — links AppKit/Foundation.
  $CXX -std=c++17 -DLOOPY_ENABLE_PLUGINS $PLUGIN_INC \
    -c src/host/native_window_controller.mm \
    -o "$P3/native_window_controller.o"
  $CXX -std=c++17 -DLOOPY_ENABLE_PLUGINS -Ithird_party/vst3sdk \
    -c third_party/vst3sdk/pluginterfaces/base/coreiids.cpp -o "$P3/coreiids.o"
  $CXX -std=c++17 -DLOOPY_ENABLE_PLUGINS -Ithird_party/vst3sdk \
    -c third_party/vst3sdk/public.sdk/source/vst/vstinitiids.cpp \
    -o "$P3/vstinitiids.o"
  # GUI IIDs (IPlugView / IPlugFrame) for the editor view interfaces (part 6).
  $CXX -std=c++17 -DLOOPY_ENABLE_PLUGINS -Ithird_party/vst3sdk \
    -c third_party/vst3sdk/public.sdk/source/common/commoniids.cpp \
    -o "$P3/commoniids.o"
  # shellcheck disable=SC2086
  $CXX "$P3"/*.o -framework CoreFoundation -framework AppKit \
    -framework Foundation \
    -o "$OUT/loopy_plugin_slot_tests.exe"
  "$OUT/loopy_plugin_slot_tests.exe"

  # NOTE: the vst3/ plugin GUID/wrapper/parity tests used to live here (also
  # Darwin-gated, so they ran in no CI job). They now build via CTest in
  # packages/loopy_engine/vst3/CMakeLists.txt — the single definition — and run
  # on macOS/Windows/Linux in the vst3-plugins-* CI jobs. Do not re-add them here.
fi
