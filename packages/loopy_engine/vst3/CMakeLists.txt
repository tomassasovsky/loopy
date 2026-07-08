# vst3/CMakeLists.txt — standalone project building "Loopy Delay" as a real
# .vst3 bundle. An independent build (umbrella: "New: VST3 plugin artifacts
# (independent build)"), not folded into loopy_engine's own SHARED-library
# build — pulls in the engine/src project via add_subdirectory only to reuse
# loopy_dsp_core (part 1) and the plugin_disabled.c stub (D-LINK), without
# editing ../src/CMakeLists.txt at all.
#
# The vendored VST3 SDK ships no CMake helper modules or sample template
# (packages/loopy_engine/third_party/vst3sdk has no *.cmake files anywhere,
# confirmed by `find . -iname "*.cmake"`) — every target below is hand-rolled
# against the raw SDK sources, referencing Steinberg's own reference `adelay`
# sample for shape only (not vendored).
cmake_minimum_required(VERSION 3.15)
project(loopy_vst3_plugins LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT APPLE)
  message(FATAL_ERROR
    "packages/loopy_engine/vst3 is macOS-only for now — part 2/12 of the VST3 "
    "pilot. Windows/Linux ports land in parts 8-9.")
endif()

get_filename_component(LOOPY_VST3_SDK_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vst3sdk" ABSOLUTE)
if(NOT EXISTS "${LOOPY_VST3_SDK_DIR}")
  message(FATAL_ERROR
    "Vendored VST3 SDK missing at ${LOOPY_VST3_SDK_DIR}. See third_party/README.md.")
endif()

# The SDK's own base/source/fdebug.h hard-errors unless one of these is
# defined (its own DEVELOPMENT/RELEASE convention, distinct from CMake's
# CMAKE_BUILD_TYPE) — applied to every SDK-consuming target below.
add_compile_definitions(
  "$<$<CONFIG:Debug>:DEVELOPMENT=1>"
  "$<$<NOT:$<CONFIG:Debug>>:RELEASE=1>"
)

# Only loopy_vst3_delay is ever requested as a build target (below), so this
# pulls loopy_dsp_core's definition into scope without also having to build
# ../src's own loopy_engine SHARED target (which has its own, unrelated
# per-OS device/MIDI dependencies out of scope here).
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/engine_src")

# --- core_plugin_disabled_stub: satisfies le_plugin_slot_process (D-LINK) ---
# engine_fx.c's LE_FX_PLUGIN row calls this unconditionally, with no #ifdef
# guard. This plugin never hosts a nested third-party plugin itself, so the
# engine's own existing non-hosting stub (already used by pre-part-8 Linux/
# Windows engine builds) is the correct symbol source here too — not new code.
add_library(core_plugin_disabled_stub STATIC
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/core/plugin_disabled.c"
)
set_target_properties(core_plugin_disabled_stub PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
)
target_include_directories(core_plugin_disabled_stub PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/core"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/host"
)

# --- sdk_common: FObject/UString/IID base layer every public.sdk/ helper needs ---
add_library(sdk_common STATIC
  "${LOOPY_VST3_SDK_DIR}/base/source/fobject.cpp"
  "${LOOPY_VST3_SDK_DIR}/base/source/fstring.cpp"
  "${LOOPY_VST3_SDK_DIR}/base/source/fdebug.cpp"
  "${LOOPY_VST3_SDK_DIR}/base/source/updatehandler.cpp"
  "${LOOPY_VST3_SDK_DIR}/base/source/baseiids.cpp"
  "${LOOPY_VST3_SDK_DIR}/base/thread/source/flock.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/common/pluginview.cpp"
  "${LOOPY_VST3_SDK_DIR}/pluginterfaces/base/coreiids.cpp"
  "${LOOPY_VST3_SDK_DIR}/pluginterfaces/base/funknown.cpp"
  "${LOOPY_VST3_SDK_DIR}/pluginterfaces/base/ustring.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/common/commoniids.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstinitiids.cpp"
)
set_target_properties(sdk_common PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(sdk_common PUBLIC "${LOOPY_VST3_SDK_DIR}")
target_link_libraries(sdk_common PUBLIC "-framework CoreFoundation")

# --- sdk: the AudioEffect/EditController/factory helper layer ---
add_library(sdk STATIC
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstcomponent.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstcomponentbase.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstaudioeffect.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstbus.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vsteditcontroller.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstparameters.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/main/pluginfactory.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/main/macmain.cpp"
)
set_target_properties(sdk PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_link_libraries(sdk PUBLIC sdk_common)

# --- loopy_vst3_delay: the plugin itself — a plain module; the .vst3 bundle
# folder is assembled by hand below (no vendored CMake bundle helper exists). --
add_library(loopy_vst3_delay MODULE
  delay/processor.cpp
  delay/controller.cpp
  delay/factory.cpp
)
set_target_properties(loopy_vst3_delay PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  PREFIX ""
  SUFFIX ""
  OUTPUT_NAME "Loopy Delay"
)
target_include_directories(loopy_vst3_delay PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/delay"
)
target_link_libraries(loopy_vst3_delay PRIVATE
  loopy_dsp_core
  core_plugin_disabled_stub
  sdk
  sdk_common
)
target_link_options(loopy_vst3_delay PRIVATE
  "-exported_symbols_list" "${LOOPY_VST3_SDK_DIR}/public.sdk/source/main/macexport.exp"
)

# --- .vst3 bundle assembly ---------------------------------------------------
set(LOOPY_DELAY_BUNDLE "${CMAKE_CURRENT_BINARY_DIR}/Loopy Delay.vst3")
add_custom_command(TARGET loopy_vst3_delay POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${LOOPY_DELAY_BUNDLE}/Contents/MacOS"
  COMMAND ${CMAKE_COMMAND} -E copy
    "$<TARGET_FILE:loopy_vst3_delay>" "${LOOPY_DELAY_BUNDLE}/Contents/MacOS/Loopy Delay"
  COMMAND ${CMAKE_COMMAND} -E copy
    "${CMAKE_CURRENT_SOURCE_DIR}/delay/Info.plist" "${LOOPY_DELAY_BUNDLE}/Contents/Info.plist"
  COMMAND /bin/sh -c "printf 'BNDL????' > '${LOOPY_DELAY_BUNDLE}/Contents/PkgInfo'"
  # Ad-hoc dev-signed for local build/test; real Developer ID signing +
  # hardened runtime + notarization for distribution is part 7 (D-SIGN).
  COMMAND codesign -f -s - "${LOOPY_DELAY_BUNDLE}"
  COMMENT "Assembling Loopy Delay.vst3 bundle"
  VERBATIM
)

# --- Local dev-install: OFF by default so CI stays clean. -------------------
option(LOOPY_VST3_DEV_INSTALL
  "Copy built VST3 bundles to ~/Library/Audio/Plug-Ins/VST3 after build" OFF)
if(LOOPY_VST3_DEV_INSTALL)
  add_custom_command(TARGET loopy_vst3_delay POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$ENV{HOME}/Library/Audio/Plug-Ins/VST3"
    COMMAND ${CMAKE_COMMAND} -E rm -rf
      "$ENV{HOME}/Library/Audio/Plug-Ins/VST3/Loopy Delay.vst3"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
      "${LOOPY_DELAY_BUNDLE}" "$ENV{HOME}/Library/Audio/Plug-Ins/VST3/Loopy Delay.vst3"
    COMMENT "Installing Loopy Delay.vst3 to ~/Library/Audio/Plug-Ins/VST3"
    VERBATIM
  )
endif()
