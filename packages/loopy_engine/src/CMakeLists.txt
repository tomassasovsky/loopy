# Builds the loopy_engine_core native audio engine as a shared library that the
# Flutter FFI plugin bundles. Consumed by the linux/ and windows/ plugin
# CMakeLists via add_subdirectory; macOS/iOS compile these same sources through
# the CocoaPods podspec instead.
cmake_minimum_required(VERSION 3.15)
project(loopy_engine_core VERSION 0.1.0 LANGUAGES C)

add_library(loopy_engine SHARED
  engine.c
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
  # miniaudio's WASAPI/DirectSound backends need COM + the multimedia timer.
  target_link_libraries(loopy_engine PRIVATE ole32 winmm)
elseif(UNIX AND NOT APPLE)
  # miniaudio dlopen()s ALSA/PulseAudio/JACK at runtime; we only need libc bits.
  find_package(Threads REQUIRED)
  target_link_libraries(loopy_engine PRIVATE Threads::Threads ${CMAKE_DL_LIBS} m)
endif()

# --- Opt-in Windows ASIO per-channel label probe ---------------------------
#
# OFF by default: the standard build is byte-for-byte unchanged and needs no
# ASIO SDK. When ON (Windows only), the engine reads per-input-channel names via
# ASIO to exclude "Loopback" inputs the way macOS does via Core Audio.
#
# The Steinberg ASIO SDK is GPLv3-or-proprietary and MUST NOT be vendored into
# this MIT repo. It is user-supplied via LOOPY_ASIO_SDK_DIR and .gitignored; the
# MIT boundary is enforced by this OFF default + .gitignore + review, NOT by CI
# (license_check.yaml scans Dart deps only). See docs/WINDOWS_ASIO.md.
option(LOOPY_ENABLE_ASIO "Build the opt-in Windows ASIO channel-label probe" OFF)
set(LOOPY_ASIO_SDK_DIR "" CACHE PATH
  "Path to a user-supplied Steinberg ASIO SDK (only used when LOOPY_ENABLE_ASIO=ON)")

if(LOOPY_ENABLE_ASIO)
  if(NOT WIN32)
    message(FATAL_ERROR "LOOPY_ENABLE_ASIO is Windows-only.")
  endif()
  if(NOT LOOPY_ASIO_SDK_DIR OR NOT EXISTS "${LOOPY_ASIO_SDK_DIR}")
    message(FATAL_ERROR
      "LOOPY_ENABLE_ASIO=ON requires LOOPY_ASIO_SDK_DIR to point at a local "
      "Steinberg ASIO SDK. See docs/WINDOWS_ASIO.md.")
  endif()
  # The probe and the SDK host glue are C++.
  enable_language(CXX)
  # Standard ASIO SDK layout (asio_sdk/common, host, host/pc). Adjust the paths
  # here if your SDK is laid out differently.
  target_sources(loopy_engine PRIVATE
    win_asio_labels.cpp
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
endif()
