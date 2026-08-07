#!/usr/bin/env bash
# Build + run the device-enumeration benchmark (NOT part of the test gate).
#
# Links the real engine sources so `--mode real` measures what actually ships
# on this platform, including the per-OS le_platform_enumerate_devices seam.
# The source list and the per-OS link flags mirror run_native_tests.sh — keep
# them in sync with it and with src/CMakeLists.txt.
#
# Usage: ./bench_devices.sh [--iters N] [--mode real|ma-lean|ma-full|ctx|all]
#   SEGNO_ALSA_ONLY=1 ./bench_devices.sh   # appliance path on the Pi
set -euo pipefail
cd "$(dirname "$0")/../../.."   # src/test/bench -> packages/segno_engine

CC=${CC:-cc}
OUT="${TMPDIR:-/tmp}"
STD="-std=gnu11 -O2 -DNDEBUG -I src/core -I src/midi -I src/asio -I src/miniaudio"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) LIBS="-lole32 -lwinmm -lm" ;;
  Darwin) LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lm" ;;
  *) LIBS="-lpthread -lm -ldl" ;;   # Linux: miniaudio dlopen()s its backends
esac

ENGINE_SRC="src/core/engine*.c src/core/lockfree_ring.c src/core/loop_clock.c \
  src/core/tempo_grid.c \
  src/core/audio_ring.c src/core/perf_drain.c src/core/perf_log_ring.c \
  src/core/layer_staging_ring.c src/core/json_read.c src/core/perf_render.c \
  src/core/plugin_disabled.c \
  src/platform/engine_*.c src/miniaudio/miniaudio_impl.c src/midi/le_midi_clock.c"

echo "== building device bench =="
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_devices.c $ENGINE_SRC $LIBS \
  -o "$OUT/segno_device_bench.exe"

"$OUT/segno_device_bench.exe" "$@"
