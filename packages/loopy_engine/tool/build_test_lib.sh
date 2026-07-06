#!/usr/bin/env bash
# build_test_lib.sh — build the engine as a shared library for device-free
# Dart tests (the sequence fuzzer's PumpedNativeEngine).
#
# Compiles the SAME engine source set as run_native_tests.sh into a shared
# lib and prints its absolute path. Consumers export it:
#
#   export LOOPY_ENGINE_LIB="$(bash packages/loopy_engine/tool/build_test_lib.sh)"
#   flutter test --tags fuzz
#
# The lib lands under build/test_lib/ inside this package (git-ignored via the
# top-level build/ ignore). Mirrors run_native_tests.sh's toolchain choices.
set -euo pipefail
cd "$(dirname "$0")/.."   # tool -> packages/loopy_engine

CC="${CC:-gcc}"
STD="-std=gnu11 -O2 -fPIC -I src/core -I src/midi -I src/asio -I src/miniaudio"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) EXT="dll";   LIBS="-lole32 -lwinmm -lm" ;;
  Darwin)               EXT="dylib"; LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lm" ;;
  *)                    EXT="so";    LIBS="-lpthread -lm -ldl" ;;
esac

OUT_DIR="build/test_lib"
OUT="$OUT_DIR/loopy_engine_test.$EXT"
mkdir -p "$OUT_DIR"

# Engine TU set mirrors run_native_tests.sh / src/CMakeLists.txt (no MIDI TUs:
# the pump surface doesn't need them and they drag in platform MIDI deps).
# shellcheck disable=SC2086
$CC $STD -shared \
  src/core/engine*.c src/core/lockfree_ring.c src/core/loop_clock.c \
  src/core/audio_ring.c src/core/perf_drain.c src/core/perf_log_ring.c src/core/plugin_disabled.c \
  src/platform/engine_*.c src/miniaudio/miniaudio_impl.c \
  $LIBS -o "$OUT" 1>&2

# The one machine-readable line: the built library's absolute path.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) cygpath -w "$(pwd)/$OUT" ;;
  *) echo "$(pwd)/$OUT" ;;
esac
