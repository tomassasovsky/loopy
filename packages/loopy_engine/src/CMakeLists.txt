# Builds the loopy_engine_core native audio engine as a shared library that the
# Flutter FFI plugin bundles. Consumed by the linux/ and windows/ plugin
# CMakeLists via add_subdirectory; macOS/iOS compile these same sources through
# the CocoaPods podspec instead.
#
# Sources are grouped into subdirectories by concern: core/ (the portable engine
# + primitives + the public ABI header), platform/ (the per-OS device seams),
# midi/ (the MIDI input/output seam), asio/ (the Windows ASIO backend), and
# miniaudio/ (the vendored backend). Every subdirectory with headers is on the
# include path below, so sources keep using flat `#include "x.h"`.
cmake_minimum_required(VERSION 3.15)
project(loopy_engine_core VERSION 0.1.0 LANGUAGES C)

# --- loopy_dsp_core: the effects DSP, split out as its own STATIC library so a
# second target (the future VST3 plugin builds, parts 2/3) can link engine_fx.c
# without duplicating the source file. Source reorganization only — no change
# to loopy_engine's public behavior, ABI, or output.
#
# Link-seam gotcha: engine_fx.c's LE_FX_PLUGIN row (fx_plugin_process) calls
# le_plugin_slot_process() unconditionally, with no #ifdef guard, so any
# target linking loopy_dsp_core has an unresolved symbol unless it also links
# something that defines it. loopy_engine gets this for free below (it links
# either host/slot.cpp when LOOPY_ENABLE_PLUGINS is on, or the stub in
# core/plugin_disabled.c when it's off) — parts 2/3 must link the stub too.
add_library(loopy_dsp_core STATIC
  core/engine_fx.c
)

# Matches loopy_engine's own C_STANDARD/atomics configuration below: this
# static lib ends up embedded in multiple .so/.dll/.dylib outputs, so PIC is
# set explicitly rather than relying on it propagating from consumers.
set_target_properties(loopy_dsp_core PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
)

if(MSVC)
  # See the matching comment on loopy_engine below: MSVC's C_STANDARD 11 alone
  # does not enable the C11 `_Atomic` keyword engine_private.h's le_fx_state
  # relies on (e.g. `_Atomic(le_plugin_slot*) plugin[LE_FX_MAX]`).
  target_compile_options(loopy_dsp_core PRIVATE /experimental:c11atomics)
endif()

# engine_fx.c's own includes ("engine_fx.h", "engine_internal.h", "fft.h") are
# flat quote-includes resolved relative to its own directory (core/); the two
# exceptions are engine_private.h -> miniaudio.h (one level over, in
# miniaudio/) and engine_fx.c's own `#include "../host/plugin_slot.h"`
# (resolved relative to the including file regardless of -I flags).
#
# PUBLIC (not PRIVATE): a consumer that links loopy_dsp_core needs these same
# two directories on its own include path to `#include "engine_fx.h"` (the
# whole point of the split — parts 2/3's VST3 targets link loopy_dsp_core
# PRIVATE and drive the DSP through engine_fx.h's public seam). PRIVATE here
# would silently fail to propagate through target_link_libraries and break
# that include the moment a consumer target is added.
target_include_directories(loopy_dsp_core PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/core"
  "${CMAKE_CURRENT_SOURCE_DIR}/miniaudio"
)

# Verified via `nm -u` on the built object: loopy_dsp_core's only unresolved
# symbols are libc/libm (calloc/free/sinf/cosf/tanf/tanhf/atan2f/expf/logf/
# powf, plus the compiler-inserted stack-protector/memcpy-check builtins) and
# le_plugin_slot_process (the link-seam gotcha above). If a future change to
# engine_fx.c (or a header it pulls in) adds a new external dependency, this
# list goes stale — re-run `nm -u` on the object and update both this comment
# and D-LINK's consumer list (parts 2/3) if so.

add_library(loopy_engine SHARED
  # ---- core/: the portable engine (S1 split into per-concern TUs) ----
  core/engine.c              # residual control-thread core + shared helpers
  core/engine_convert.c      # pure sample-format conversion + ASIO buffer math
  # core/engine_fx.c lives in loopy_dsp_core above (linked PRIVATE below) so a
  # second target (future VST3 plugin builds) can link it too.
  core/engine_session.c      # session export / import / commit
  core/engine_devices.c      # device discovery, loopback, id resolution, backend
  core/engine_snapshot.c     # published-state snapshots + visualization reads
  core/engine_process.c      # THE audio-thread TU (le_engine_process + transport)
  core/engine_commands.c     # control-thread command producers
  # The miniaudio device backend (le_device_backend.h), compiled unconditionally
  # — the only device backend this build ships; ASIO slots in behind
  # le_select_backend.
  core/engine_miniaudio.c
  core/lockfree_ring.c
  core/loop_clock.c
  core/audio_ring.c          # float SPSC ring (performance-recording capture)
  core/perf_log_ring.c       # perf event log: SPSC ring of frame-tagged le_command entries
  core/layer_staging_ring.c  # retired-layer PCM staging ring (persist before pool eviction)
  core/perf_drain.c          # perf-capture drain thread: rings -> raw PCM + sidecar
  core/json_read.c           # minimal read-only JSON parser (performance.json)
  core/perf_render.c         # offline renderer: replay capture dir -> dry stems
  # Control-thread plugin-slot lifecycle (load/clear + quiescent handshake).
  # Always compiled; calls le_plugin_slot_create which is the real host on a
  # plugin build and a NULL-returning stub otherwise.
  core/engine_plugin.c
  # le_plugin_* stubs for non-LOOPY_ENABLE_PLUGINS builds (Linux today; macOS
  # and Windows compile the real host). Internally #ifndef-guarded, so it
  # compiles to an empty object when plugins are enabled and
  # host/plugin_scan.cpp + host/slot.cpp provide the real symbols.
  core/plugin_disabled.c
  # ---- platform/: per-OS device seams (engine_platform.h) ----
  # Each is wrapped whole in its OS guard, so the two that don't match the build
  # target compile to near-empty objects — every build lists all three.
  platform/engine_linux.c
  platform/engine_apple.c
  platform/engine_windows.c
  # ---- midi/: native USB MIDI seam (le_midi_backend.h) ----
  # midi.c is the portable core (ring + parser + FFI surface, no OS MIDI
  # headers); the three backend TUs are each OS-guarded like the platform seam.
  midi/midi.c
  midi/midi_backend_linux.c
  midi/midi_backend_apple.c
  midi/midi_backend_windows.c
  # ---- miniaudio/: the vendored backend ----
  miniaudio/miniaudio_impl.c
)

# C11 gives us <stdatomic.h> for the lock-free ring and snapshot publication.
set_target_properties(loopy_engine PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
  OUTPUT_NAME "loopy_engine"
)

if(MSVC)
  # CMake's C_STANDARD 11 only emits /std:c11, which is NOT enough for MSVC to
  # accept the C11 `_Atomic` keyword / <stdatomic.h> — the cl frontend still
  # rejects its own <vcruntime_c11_stdatomic.h> unless C11 atomics are explicitly
  # enabled. Verified empirically on VS 2022 17.11 (cl 14.41): /std:c11 alone
  # fails, /std:c11 /experimental:c11atomics compiles. The flag exists since
  # VS 2022 17.5; despite MS docs claiming it became default in 17.8, this
  # toolset still requires it. Without it the whole Windows engine build fails on
  # lockfree_ring.h's `_Atomic size_t` head/tail.
  target_compile_options(loopy_engine PRIVATE /experimental:c11atomics)
  # The C++ TUs (ASIO backend, plugin host) use std::vector/string and may
  # throw; MSVC needs /EHsc to enable unwind semantics. Scoped to C++ via the
  # genex so the C TUs (the bulk of the engine) are unaffected.
  target_compile_options(loopy_engine PRIVATE $<$<COMPILE_LANGUAGE:CXX>:/EHsc>)
  # The portable engine uses standard C string functions (strncpy, etc.); MSVC
  # flags every one with C4996 "consider strncpy_s". They're used correctly and
  # must stay portable (no _s variants on Clang/GCC), so quiet the deprecation
  # rather than litter the cross-platform source with MSVC-only annotations.
  target_compile_definitions(loopy_engine PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

# Every subdirectory holding headers is on the include path, so sources keep
# their flat `#include "engine_private.h"` / "miniaudio.h" / "le_midi_backend.h"
# form regardless of which folder they (or the includer) live in.
target_include_directories(loopy_engine PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/core"
  "${CMAKE_CURRENT_SOURCE_DIR}/midi"
  "${CMAKE_CURRENT_SOURCE_DIR}/asio"
  "${CMAKE_CURRENT_SOURCE_DIR}/miniaudio"
)

# engine_fx.c's object code now arrives via loopy_dsp_core instead of a direct
# compile; PRIVATE keeps the static lib an implementation detail (it does not
# leak into loopy_engine's own public link interface).
target_link_libraries(loopy_engine PRIVATE loopy_dsp_core)

# DART_SHARED_LIB keeps the FFI-exported symbols visible in the stripped release
# library (mirrors the flutter plugin_ffi template contract).
target_compile_definitions(loopy_engine PUBLIC DART_SHARED_LIB)

if(WIN32)
  # miniaudio's Windows device backends need COM + the multimedia timer; the
  # WinMM MIDI-input backend (midi_backend_windows.c) also links winmm.
  target_link_libraries(loopy_engine PRIVATE ole32 winmm)
elseif(UNIX AND NOT APPLE)
  # miniaudio dlopen()s ALSA/PulseAudio/JACK at runtime; we only need libc bits.
  find_package(Threads REQUIRED)
  target_link_libraries(loopy_engine PRIVATE Threads::Threads ${CMAKE_DL_LIBS} m)
  # The ALSA-sequencer MIDI backend (midi_backend_linux.c) links libasound
  # directly (unlike miniaudio, which dlopen()s it). Needs libasound2-dev.
  find_package(ALSA REQUIRED)
  target_link_libraries(loopy_engine PRIVATE ALSA::ALSA)
endif()

# The CocoaPods (macOS/iOS) build compiles these sources via the podspec, not
# CMake, and links CoreMIDI there. This APPLE branch only matters if the engine
# is ever built through CMake on Apple (e.g. the native test harness).
if(APPLE)
  target_link_libraries(loopy_engine PRIVATE "-framework CoreMIDI"
    "-framework CoreFoundation")
endif()

# --- Windows ASIO (duplex backend + per-channel label probe) ---------------
#
# ON by default on Windows: the engine opens ASIO for full-channel-count duplex
# audio and reads per-input-channel names to exclude "Loopback" inputs the way
# macOS does via Core Audio. macOS/Linux keep the miniaudio backend (OFF there).
#
# The Steinberg ASIO SDK is vendored under third_party/asiosdk (this repo is
# GPLv3; the Steinberg license file is kept intact alongside it). ASIO is built
# by default on Windows; macOS/Linux keep the miniaudio backend (OFF there).
if(WIN32)
  option(LOOPY_ENABLE_ASIO "Build Windows ASIO support" ON)
else()
  option(LOOPY_ENABLE_ASIO "Build Windows ASIO support" OFF)
endif()
# The Flutter Windows build drives this CMake through the plugin and cannot
# forward -D cache flags, so honor an env override for the enable flag (e.g. a
# non-ASIO CI build): set LOOPY_ENABLE_ASIO=OFF to skip it. The env value is
# applied after option() so it wins over a stale cached value too.
if(DEFINED ENV{LOOPY_ENABLE_ASIO} AND NOT "$ENV{LOOPY_ENABLE_ASIO}" STREQUAL "")
  set(LOOPY_ENABLE_ASIO "$ENV{LOOPY_ENABLE_ASIO}")
endif()

# The Steinberg ASIO SDK is vendored and used as-is — the path is fixed, not
# configurable. A plain (non-cache) variable resolved every configure to a
# normalized absolute path, so it can never go stale and is found regardless of
# where CMake is invoked from.
get_filename_component(LOOPY_ASIO_SDK_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/asiosdk" ABSOLUTE)

if(LOOPY_ENABLE_ASIO)
  if(NOT WIN32)
    message(FATAL_ERROR "LOOPY_ENABLE_ASIO is Windows-only.")
  endif()
  if(NOT EXISTS "${LOOPY_ASIO_SDK_DIR}")
    message(FATAL_ERROR
      "LOOPY_ENABLE_ASIO=ON but the vendored Steinberg ASIO SDK is missing at "
      "${LOOPY_ASIO_SDK_DIR} (a broken or partial checkout?). Restore it. "
      "See docs/WINDOWS_ASIO.md.")
  endif()
  # The probe, the duplex device backend, and the SDK host glue are C++.
  enable_language(CXX)
  # Standard ASIO SDK layout (asio_sdk/common, host, host/pc). Adjust the paths
  # here if your SDK is laid out differently. win_asio_device.cpp (Part 2) is the
  # real ASIO duplex backend selected by le_select_backend; it links the SAME SDK
  # host objects as the label probe — no new SDK sources are needed.
  target_sources(loopy_engine PRIVATE
    asio/win_asio_labels.cpp
    asio/win_asio_device.cpp
    "${LOOPY_ASIO_SDK_DIR}/common/asio.cpp"
    "${LOOPY_ASIO_SDK_DIR}/host/asiodrivers.cpp"
    "${LOOPY_ASIO_SDK_DIR}/host/pc/asiolist.cpp"
  )
  target_include_directories(loopy_engine PRIVATE
    "${LOOPY_ASIO_SDK_DIR}/common"
    "${LOOPY_ASIO_SDK_DIR}/host"
    "${LOOPY_ASIO_SDK_DIR}/host/pc"
  )
  target_compile_definitions(loopy_engine PRIVATE LOOPY_ENABLE_ASIO)
  # The SDK host glue (asiolist.cpp) calls the Win32 registry/char APIs with ANSI
  # `char*` string literals, but the Flutter Windows build defines UNICODE, which
  # binds those names to the wide (…W) variants and fails to compile. The SDK is
  # an ANSI codebase, so compile its sources with UNICODE/_UNICODE undefined
  # (MSVC `/U`). Our own ASIO TUs use no …A/…W string APIs, so they keep UNICODE.
  if(MSVC)
    set_source_files_properties(
      "${LOOPY_ASIO_SDK_DIR}/common/asio.cpp"
      "${LOOPY_ASIO_SDK_DIR}/host/asiodrivers.cpp"
      "${LOOPY_ASIO_SDK_DIR}/host/pc/asiolist.cpp"
      PROPERTIES COMPILE_OPTIONS "/UUNICODE;/U_UNICODE")
  endif()
endif()

# --- VST3 + CLAP plugin hosting (vendored SDK include roots) ----------------
#
# Plugin hosting (third_party/vst3sdk + third_party/clap, both MIT — see
# third_party/README.md) is sequenced macOS-first: the macOS build (SPM
# Package.swift / CocoaPods podspec) defines LOOPY_ENABLE_PLUGINS and compiles
# the host sources directly. On Windows/Linux this is OFF by default; the engine
# then links only the le_plugin_scan_* stub (core/plugin_scan_disabled.c, above)
# so FFI resolves, and the build stays byte-identical apart from that stub. When
# enabled, the VST3/CLAP scan + host backends compile here too. The scan/host
# directory walkers are implemented for macOS and Windows (part 8); Linux lands
# in part 9, so an enabled Linux build scans nothing yet.
#
# Default-ON on Windows (like ASIO above): the Windows build ships plugin hosting
# out of the box. macOS drives this through the podspec, not CMake; Linux keeps
# it OFF until part 9. The env override below still wins for a non-plugin build.
if(WIN32)
  option(LOOPY_ENABLE_PLUGINS "Build VST3/CLAP plugin hosting" ON)
else()
  option(LOOPY_ENABLE_PLUGINS "Build VST3/CLAP plugin hosting" OFF)
endif()
# As with ASIO, the Flutter build drives CMake through the plugin and cannot
# forward -D cache flags, so honor an env override applied after option() (e.g.
# a CI build that opts into the Windows/Linux ports early).
if(DEFINED ENV{LOOPY_ENABLE_PLUGINS} AND NOT "$ENV{LOOPY_ENABLE_PLUGINS}" STREQUAL "")
  set(LOOPY_ENABLE_PLUGINS "$ENV{LOOPY_ENABLE_PLUGINS}")
endif()

# Vendored and used as-is — fixed (non-configurable) paths normalized to an
# absolute location every configure, so they can never go stale.
get_filename_component(LOOPY_VST3_SDK_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vst3sdk" ABSOLUTE)
get_filename_component(LOOPY_CLAP_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/clap/include" ABSOLUTE)

if(LOOPY_ENABLE_PLUGINS)
  if(NOT EXISTS "${LOOPY_VST3_SDK_DIR}" OR NOT EXISTS "${LOOPY_CLAP_DIR}")
    message(FATAL_ERROR
      "LOOPY_ENABLE_PLUGINS=ON but the vendored VST3/CLAP SDKs are missing under "
      "${CMAKE_CURRENT_SOURCE_DIR}/../third_party (a broken or partial checkout?). "
      "Restore them. See third_party/README.md.")
  endif()
  # The VST3 SDK is C++; CLAP is a C header API consumed from C++.
  enable_language(CXX)
  target_include_directories(loopy_engine PRIVATE
    "${LOOPY_VST3_SDK_DIR}"
    "${LOOPY_CLAP_DIR}"
  )
  target_compile_definitions(loopy_engine PRIVATE LOOPY_ENABLE_PLUGINS)
  # The scan ABI + thread and the two format backends, plus the three vendored
  # IID translation units the host queryInterface()s against (the same set the
  # macOS podspec compiles via its vst3_*iids.cpp forwarders):
  #   - coreiids.cpp    : pluginterfaces base IIDs (IComponent / scanning).
  #   - commoniids.cpp  : the GUI IIDs (IPlugView / IPlugFrame) the editor needs.
  #   - vstinitiids.cpp : the VST-domain class IIDs (IAudioProcessor / …).
  # The backends' directory walkers + DLL loading are implemented for macOS and
  # Windows (part 8); Linux compiles to empty until part 9.
  target_sources(loopy_engine PRIVATE
    host/plugin_scan.cpp
    host/scan_vst3.cpp
    host/scan_clap.cpp
    host/slot.cpp
    host/host_vst3.cpp
    host/host_clap.cpp
    "${LOOPY_VST3_SDK_DIR}/pluginterfaces/base/coreiids.cpp"
    "${LOOPY_VST3_SDK_DIR}/public.sdk/source/common/commoniids.cpp"
    "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstinitiids.cpp"
  )
  if(WIN32)
    # The host-owned HWND editor window (native_window_controller_win.cpp, the
    # Win32 analogue of native_window_controller.mm compiled by the macOS
    # podspec). user32/gdi32 back the Win32 window calls; both are in CMake's
    # default Windows link set, listed here for intent.
    target_sources(loopy_engine PRIVATE host/native_window_controller_win.cpp)
    target_link_libraries(loopy_engine PRIVATE user32 gdi32)
  endif()
  set_target_properties(loopy_engine PROPERTIES CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON)
endif()
