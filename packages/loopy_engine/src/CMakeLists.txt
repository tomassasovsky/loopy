# Builds the loopy_engine_core native audio engine as a shared library that the
# Flutter FFI plugin bundles. Consumed by the linux/ and windows/ plugin
# CMakeLists via add_subdirectory; macOS/iOS compile these same sources through
# the CocoaPods podspec instead.
cmake_minimum_required(VERSION 3.15)
project(loopy_engine_core VERSION 0.1.0 LANGUAGES C)

add_library(loopy_engine SHARED
  engine.c
  # Pure sample-format conversion + ASIO buffer-size math (S1 split from
  # engine.c). No engine state, no device headers; unit-tested off-thread.
  engine_convert.c
  # The miniaudio device backend (le_device_backend.h). Compiled unconditionally
  # — it is the only device backend this build ships; the opt-in ASIO backend
  # slots in behind le_select_backend later.
  engine_miniaudio.c
  # Per-OS platform-seam translation units (engine_platform.h). Each is wrapped
  # whole in its OS guard, so the two that don't match the build target compile
  # to near-empty objects — every build lists all three unconditionally.
  engine_linux.c
  engine_apple.c
  engine_windows.c
  # Native USB MIDI input seam (le_midi_backend.h). midi.c is the portable core
  # (ring + parser + FFI surface, no OS MIDI headers); the three backend TUs are
  # each wrapped whole in their OS guard, so the two that don't match the build
  # target compile to near-empty objects — every build lists all three, exactly
  # like the engine_*.c platform seam.
  midi.c
  midi_backend_linux.c
  midi_backend_apple.c
  midi_backend_windows.c
  lockfree_ring.c
  loop_clock.c
  miniaudio_impl.c
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
  # The portable engine uses standard C string functions (strncpy, etc.); MSVC
  # flags every one with C4996 "consider strncpy_s". They're used correctly and
  # must stay portable (no _s variants on Clang/GCC), so quiet the deprecation
  # rather than litter the cross-platform source with MSVC-only annotations.
  target_compile_definitions(loopy_engine PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

target_include_directories(loopy_engine PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/miniaudio"
)

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
    win_asio_labels.cpp
    win_asio_device.cpp
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
