# Builds the loopy_engine_core native audio engine as a shared library that the
# Flutter FFI plugin bundles. Consumed by the linux/ and windows/ plugin
# CMakeLists via add_subdirectory; macOS/iOS compile these same sources through
# the CocoaPods podspec instead.
cmake_minimum_required(VERSION 3.15)
project(loopy_engine_core VERSION 0.1.0 LANGUAGES C)

add_library(loopy_engine SHARED
  engine.c
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
