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
  src/core/audio_ring.c src/core/perf_drain.c src/core/perf_log_ring.c src/core/layer_staging_ring.c src/core/json_read.c src/core/perf_render.c src/core/plugin_disabled.c \
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

  # GUID-drift regression test (umbrella D-GUID) for the "Loopy Delay" VST3
  # plugin (vst3/delay) — independently hardcodes the same 16 bytes ids.h
  # declares, so an accidental edit to a minted GUID fails loudly here
  # instead of silently breaking every .als export referencing it.
  echo "== building vst3 delay GUID-drift test =="
  $CXX -std=c++17 -Ithird_party/vst3sdk -Ivst3/delay \
    vst3/delay/test_vst3_delay_ids.cpp \
    -o "$OUT/loopy_vst3_delay_ids_tests.exe"
  "$OUT/loopy_vst3_delay_ids_tests.exe"

  # Wrapper-level tests (umbrella Testing Strategy: "part 2/3 add
  # wrapper-level tests — parameter round-trip, default values match
  # le_fx_defaults"). Instantiates Processor/Controller directly (no dlopen,
  # no real host) against the same SDK helper sources vst3/CMakeLists.txt's
  # sdk/sdk_common targets compile.
  echo "== building vst3 delay wrapper tests =="
  VST3_SDK_SRC="third_party/vst3sdk/pluginterfaces/base/coreiids.cpp \
    third_party/vst3sdk/pluginterfaces/base/funknown.cpp \
    third_party/vst3sdk/pluginterfaces/base/ustring.cpp \
    third_party/vst3sdk/public.sdk/source/vst/vstinitiids.cpp \
    third_party/vst3sdk/public.sdk/source/vst/vstcomponent.cpp \
    third_party/vst3sdk/public.sdk/source/vst/vstcomponentbase.cpp \
    third_party/vst3sdk/public.sdk/source/vst/vstaudioeffect.cpp \
    third_party/vst3sdk/public.sdk/source/vst/vstbus.cpp \
    third_party/vst3sdk/public.sdk/source/vst/vsteditcontroller.cpp \
    third_party/vst3sdk/public.sdk/source/vst/vstparameters.cpp \
    third_party/vst3sdk/public.sdk/source/common/commoniids.cpp \
    third_party/vst3sdk/public.sdk/source/common/pluginview.cpp \
    third_party/vst3sdk/public.sdk/source/common/memorystream.cpp \
    third_party/vst3sdk/base/source/fobject.cpp \
    third_party/vst3sdk/base/source/fstring.cpp \
    third_party/vst3sdk/base/source/fdebug.cpp \
    third_party/vst3sdk/base/source/updatehandler.cpp \
    third_party/vst3sdk/base/source/baseiids.cpp \
    third_party/vst3sdk/base/thread/source/flock.cpp"
  # shellcheck disable=SC2086
  $CXX -std=c++17 -DDEVELOPMENT=1 -Ithird_party/vst3sdk -Isrc/core -Isrc/miniaudio -Ivst3/delay -Ivst3/test \
    vst3/delay/test_vst3_delay_wrapper.cpp \
    vst3/delay/processor.cpp vst3/delay/controller.cpp \
    src/core/engine_fx.c src/core/plugin_disabled.c \
    $VST3_SDK_SRC \
    -framework CoreFoundation \
    -o "$OUT/loopy_vst3_delay_wrapper_tests.exe"
  "$OUT/loopy_vst3_delay_wrapper_tests.exe"

  # Same two test layers as Delay (part 2), repeated for "Loopy Reverb"
  # (part 3) — GUID-drift regression test first, then wrapper-level tests
  # (including the mono-input stereo-tail check the part 3 plan calls out).
  echo "== building vst3 reverb GUID-drift test =="
  $CXX -std=c++17 -Ithird_party/vst3sdk -Ivst3/reverb \
    vst3/reverb/test_vst3_reverb_ids.cpp \
    -o "$OUT/loopy_vst3_reverb_ids_tests.exe"
  "$OUT/loopy_vst3_reverb_ids_tests.exe"

  echo "== building vst3 reverb wrapper tests =="
  # shellcheck disable=SC2086
  $CXX -std=c++17 -DDEVELOPMENT=1 -Ithird_party/vst3sdk -Isrc/core -Isrc/miniaudio -Ivst3/reverb -Ivst3/test \
    vst3/reverb/test_vst3_reverb_wrapper.cpp \
    vst3/reverb/processor.cpp vst3/reverb/controller.cpp \
    src/core/engine_fx.c src/core/plugin_disabled.c \
    $VST3_SDK_SRC \
    -framework CoreFoundation \
    -o "$OUT/loopy_vst3_reverb_wrapper_tests.exe"
  "$OUT/loopy_vst3_reverb_wrapper_tests.exe"

  # Golden-parity audio-diff harness (part 4, umbrella D-VALIDATE): drives
  # each plugin's real GetPluginFactory()->createInstance()->process() path
  # (vst3/test/host_harness.cpp) and diffs its output against a direct
  # fx_apply_chain call over the identical signal/params, across a fixed
  # signal x sample-rate x param-combo x block-size matrix. One binary per
  # plugin — each factory.cpp defines a global (non-namespaced)
  # GetPluginFactory(), so Delay's and Reverb's can't link into the same
  # binary. Needs pluginfactory.cpp (unlike the wrapper tests above, which
  # instantiate Processor/Controller directly and never touch the factory).
  echo "== building vst3 delay parity harness =="
  # shellcheck disable=SC2086
  $CXX -std=c++17 -DDEVELOPMENT=1 -Ithird_party/vst3sdk -Isrc/core -Isrc/miniaudio \
    -Ivst3/delay -Ivst3/test \
    vst3/test/host_harness.cpp vst3/test/test_delay_parity.cpp \
    vst3/delay/processor.cpp vst3/delay/controller.cpp vst3/delay/factory.cpp \
    src/core/engine_fx.c src/core/plugin_disabled.c \
    third_party/vst3sdk/public.sdk/source/main/pluginfactory.cpp \
    $VST3_SDK_SRC \
    -framework CoreFoundation \
    -o "$OUT/loopy_vst3_delay_parity_tests.exe"
  "$OUT/loopy_vst3_delay_parity_tests.exe"

  echo "== building vst3 reverb parity harness =="
  # shellcheck disable=SC2086
  $CXX -std=c++17 -DDEVELOPMENT=1 -Ithird_party/vst3sdk -Isrc/core -Isrc/miniaudio \
    -Ivst3/reverb -Ivst3/test \
    vst3/test/host_harness.cpp vst3/test/test_reverb_parity.cpp \
    vst3/reverb/processor.cpp vst3/reverb/controller.cpp vst3/reverb/factory.cpp \
    src/core/engine_fx.c src/core/plugin_disabled.c \
    third_party/vst3sdk/public.sdk/source/main/pluginfactory.cpp \
    $VST3_SDK_SRC \
    -framework CoreFoundation \
    -o "$OUT/loopy_vst3_reverb_parity_tests.exe"
  "$OUT/loopy_vst3_reverb_parity_tests.exe"

  # Same GUID-drift + golden-parity test pair as Delay/Reverb, repeated for
  # "Loopy Echo" (part 5) — no wrapper-level test file this time, since the
  # umbrella's Testing Strategy scopes parts 5-9 to exactly these two test
  # layers per new plugin.
  echo "== building vst3 echo GUID-drift test =="
  $CXX -std=c++17 -Ithird_party/vst3sdk -Ivst3/echo \
    vst3/echo/test_vst3_echo_ids.cpp \
    -o "$OUT/loopy_vst3_echo_ids_tests.exe"
  "$OUT/loopy_vst3_echo_ids_tests.exe"

  echo "== building vst3 echo parity harness =="
  # shellcheck disable=SC2086
  $CXX -std=c++17 -DDEVELOPMENT=1 -Ithird_party/vst3sdk -Isrc/core -Isrc/miniaudio \
    -Ivst3/echo -Ivst3/test \
    vst3/test/host_harness.cpp vst3/test/test_echo_parity.cpp \
    vst3/echo/processor.cpp vst3/echo/controller.cpp vst3/echo/factory.cpp \
    src/core/engine_fx.c src/core/plugin_disabled.c \
    third_party/vst3sdk/public.sdk/source/main/pluginfactory.cpp \
    $VST3_SDK_SRC \
    -framework CoreFoundation \
    -o "$OUT/loopy_vst3_echo_parity_tests.exe"
  "$OUT/loopy_vst3_echo_parity_tests.exe"

  # Same GUID-drift + golden-parity test pair, repeated for "Loopy Drive"
  # (part 6) — the first plugin to exercise the widened (part 6) harness at a
  # narrower paramCount=2 than Delay/Reverb/Echo's fixed 3.
  echo "== building vst3 drive GUID-drift test =="
  $CXX -std=c++17 -Ithird_party/vst3sdk -Ivst3/drive \
    vst3/drive/test_vst3_drive_ids.cpp \
    -o "$OUT/loopy_vst3_drive_ids_tests.exe"
  "$OUT/loopy_vst3_drive_ids_tests.exe"

  echo "== building vst3 drive parity harness =="
  # shellcheck disable=SC2086
  $CXX -std=c++17 -DDEVELOPMENT=1 -Ithird_party/vst3sdk -Isrc/core -Isrc/miniaudio \
    -Ivst3/drive -Ivst3/test \
    vst3/test/host_harness.cpp vst3/test/test_drive_parity.cpp \
    vst3/drive/processor.cpp vst3/drive/controller.cpp vst3/drive/factory.cpp \
    src/core/engine_fx.c src/core/plugin_disabled.c \
    third_party/vst3sdk/public.sdk/source/main/pluginfactory.cpp \
    $VST3_SDK_SRC \
    -framework CoreFoundation \
    -o "$OUT/loopy_vst3_drive_parity_tests.exe"
  "$OUT/loopy_vst3_drive_parity_tests.exe"

  # Same GUID-drift + golden-parity test pair, repeated for "Loopy Filter"
  # (part 7) — reuses the part-6-generalized harness unchanged (also a
  # paramCount=2 effect).
  echo "== building vst3 filter GUID-drift test =="
  $CXX -std=c++17 -Ithird_party/vst3sdk -Ivst3/filter \
    vst3/filter/test_vst3_filter_ids.cpp \
    -o "$OUT/loopy_vst3_filter_ids_tests.exe"
  "$OUT/loopy_vst3_filter_ids_tests.exe"

  echo "== building vst3 filter parity harness =="
  # shellcheck disable=SC2086
  $CXX -std=c++17 -DDEVELOPMENT=1 -Ithird_party/vst3sdk -Isrc/core -Isrc/miniaudio \
    -Ivst3/filter -Ivst3/test \
    vst3/test/host_harness.cpp vst3/test/test_filter_parity.cpp \
    vst3/filter/processor.cpp vst3/filter/controller.cpp vst3/filter/factory.cpp \
    src/core/engine_fx.c src/core/plugin_disabled.c \
    third_party/vst3sdk/public.sdk/source/main/pluginfactory.cpp \
    $VST3_SDK_SRC \
    -framework CoreFoundation \
    -o "$OUT/loopy_vst3_filter_parity_tests.exe"
  "$OUT/loopy_vst3_filter_parity_tests.exe"

  # Same GUID-drift + golden-parity test pair, repeated for "Loopy Tremolo"
  # (part 8) — reuses the part-6-generalized harness unchanged (also a
  # paramCount=2 effect); the harness's own block-size sweep doubles as the
  # LFO block-boundary-phase check across the min (slowest) / max (fastest)
  # Rate combos.
  echo "== building vst3 tremolo GUID-drift test =="
  $CXX -std=c++17 -Ithird_party/vst3sdk -Ivst3/tremolo \
    vst3/tremolo/test_vst3_tremolo_ids.cpp \
    -o "$OUT/loopy_vst3_tremolo_ids_tests.exe"
  "$OUT/loopy_vst3_tremolo_ids_tests.exe"

  echo "== building vst3 tremolo parity harness =="
  # shellcheck disable=SC2086
  $CXX -std=c++17 -DDEVELOPMENT=1 -Ithird_party/vst3sdk -Isrc/core -Isrc/miniaudio \
    -Ivst3/tremolo -Ivst3/test \
    vst3/test/host_harness.cpp vst3/test/test_tremolo_parity.cpp \
    vst3/tremolo/processor.cpp vst3/tremolo/controller.cpp vst3/tremolo/factory.cpp \
    src/core/engine_fx.c src/core/plugin_disabled.c \
    third_party/vst3sdk/public.sdk/source/main/pluginfactory.cpp \
    $VST3_SDK_SRC \
    -framework CoreFoundation \
    -o "$OUT/loopy_vst3_tremolo_parity_tests.exe"
  "$OUT/loopy_vst3_tremolo_parity_tests.exe"
fi
