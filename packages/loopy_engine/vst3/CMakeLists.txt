# vst3/CMakeLists.txt — standalone project building all seven Loopy FX VST3
# plugins as real .vst3 bundles: "Loopy Delay" (part 2), "Loopy Reverb"
# (part 3), "Loopy Echo" (part 5), "Loopy Drive" (part 6), "Loopy Filter"
# (part 7), "Loopy Tremolo" (part 8), and "Loopy Octaver" (part 9) — the
# full built-in effect set (umbrella D-ALL-EFFECTS). An independent build
# (umbrella: "New: VST3 plugin artifacts (independent build)"), not folded
# into loopy_engine's own SHARED-library build — pulls in the engine/src
# project via add_subdirectory only to reuse loopy_dsp_core (part 1) and the
# plugin_disabled.c stub (D-LINK), without editing ../src/CMakeLists.txt at
# all.
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

if(NOT APPLE AND NOT WIN32)
  message(FATAL_ERROR
    "packages/loopy_engine/vst3 builds on macOS (parts 2-9) and Windows "
    "(part 13). The Linux port lands in part 14 of the 17-part VST3 plan.")
endif()

if(MSVC)
  # The vendored SDK + engine core use strncpy/sprintf-style calls; silence the
  # CRT deprecation warnings-as-noise (mirrors src/CMakeLists.txt). The C11
  # atomics flag the engine core needs is applied by loopy_dsp_core itself
  # (PRIVATE, in src/CMakeLists.txt) and rides in via add_subdirectory above.
  # _USE_MATH_DEFINES makes <math.h> expose M_PI etc. (the parity harness's test
  # signal generator uses M_PI) — MSVC gates them behind this, unlike libc++/glibc.
  add_compile_definitions(_CRT_SECURE_NO_WARNINGS _USE_MATH_DEFINES)
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

# --- Per-OS build layer (parts 13/14) ---------------------------------------
# The DSP and every plugin TU are portable C++17; only three things differ per
# OS, each with a first-class SDK equivalent already vendored. These variables
# isolate that layer so the plugin/target blocks below stay OS-agnostic. The
# WIN32/else() values are defined now but not reached until the guard above is
# lifted (Windows = part 13, Linux = part 14); today only the APPLE branch runs.
if(APPLE)
  set(LOOPY_VST3_MODULE_ENTRY
    "${LOOPY_VST3_SDK_DIR}/public.sdk/source/main/macmain.cpp")
  set(LOOPY_VST3_MODULE_SUFFIX "")
  # macOS whitelists exported symbols via a linker list.
  set(LOOPY_VST3_EXPORT_LINK_OPTS
    "-exported_symbols_list"
    "${LOOPY_VST3_SDK_DIR}/public.sdk/source/main/macexport.exp")
elseif(WIN32)
  set(LOOPY_VST3_MODULE_ENTRY
    "${LOOPY_VST3_SDK_DIR}/public.sdk/source/main/dllmain.cpp")
  set(LOOPY_VST3_MODULE_SUFFIX ".vst3")
  # Windows exports via SMTG_EXPORT_SYMBOL (__declspec(dllexport)) — no .def.
  set(LOOPY_VST3_EXPORT_LINK_OPTS "")
else()
  set(LOOPY_VST3_MODULE_ENTRY
    "${LOOPY_VST3_SDK_DIR}/public.sdk/source/main/linuxmain.cpp")
  set(LOOPY_VST3_MODULE_SUFFIX ".so")
  # Linux exports via SMTG_EXPORT_SYMBOL (visibility("default")) — no .lds.
  set(LOOPY_VST3_EXPORT_LINK_OPTS "")
endif()

# Only the seven loopy_vst3_* targets defined below are ever requested as
# build targets, so this pulls loopy_dsp_core's definition into scope
# without also having to build ../src's own loopy_engine SHARED target
# (which has its own, unrelated per-OS device/MIDI dependencies out of scope
# here).
# EXCLUDE_FROM_ALL: pull in loopy_dsp_core's definition without adding ../src's
# own loopy_engine SHARED target to the default build. That SHARED lib builds on
# macOS via the CocoaPods podspec (Classes/ forwarders), NOT this CMake, so a
# plain `cmake --build` (all) of this project must not try to link it — it only
# needs loopy_dsp_core + core_plugin_disabled_stub, which build on demand when
# the plugin/test targets reference them.
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/engine_src" EXCLUDE_FROM_ALL)

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
  # memorystream.cpp is needed by the wrapper tests' MemoryStream round-trip
  # (test_vst3_*_wrapper.cpp). Unreferenced by the plugin MODULE targets, so it
  # is not pulled into any .vst3 — the assembled bundles stay byte-identical.
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/common/memorystream.cpp"
)
set_target_properties(sdk_common PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(sdk_common PUBLIC "${LOOPY_VST3_SDK_DIR}")
if(APPLE)
  target_link_libraries(sdk_common PUBLIC "-framework CoreFoundation")
endif()

# --- sdk: the AudioEffect/EditController/factory helper layer ---
add_library(sdk STATIC
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstcomponent.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstcomponentbase.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstaudioeffect.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstbus.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vsteditcontroller.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/vst/vstparameters.cpp"
  "${LOOPY_VST3_SDK_DIR}/public.sdk/source/main/pluginfactory.cpp"
  "${LOOPY_VST3_MODULE_ENTRY}"
)
set_target_properties(sdk PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_link_libraries(sdk PUBLIC sdk_common)

# --- Local dev-install: OFF by default so CI stays clean. -------------------
option(LOOPY_VST3_DEV_INSTALL
  "Copy built VST3 bundles to ~/Library/Audio/Plug-Ins/VST3 after build" OFF)

# Assembles a .vst3 bundle by hand for a MODULE target (no vendored CMake
# bundle helper exists — packages/loopy_engine/third_party/vst3sdk has no
# *.cmake files anywhere): Contents/MacOS/<display_name> (the built binary),
# Contents/Info.plist (hand-authored, from <source_dir>/Info.plist),
# Contents/PkgInfo, ad-hoc codesigned. Shared by both loopy_vst3_delay (part
# 2) and loopy_vst3_reverb (part 3) rather than duplicating this per plugin.
function(loopy_vst3_add_bundle target display_name source_dir)
  set(bundle "${CMAKE_CURRENT_BINARY_DIR}/${display_name}.vst3")
  if(APPLE)
    # macOS bundle: Contents/MacOS/<name> + Info.plist + PkgInfo, ad-hoc signed.
    set(module_in_bundle "${bundle}/Contents/MacOS/${display_name}")
    add_custom_command(TARGET ${target} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E make_directory "${bundle}/Contents/MacOS"
      COMMAND ${CMAKE_COMMAND} -E copy
        "$<TARGET_FILE:${target}>" "${module_in_bundle}"
      COMMAND ${CMAKE_COMMAND} -E copy
        "${source_dir}/Info.plist" "${bundle}/Contents/Info.plist"
      COMMAND /bin/sh -c "printf 'BNDL????' > '${bundle}/Contents/PkgInfo'"
      # Ad-hoc dev-signed for local build/test; real Developer ID signing +
      # hardened runtime + notarization for distribution is part 12 (D-SIGN).
      COMMAND codesign -f -s - "${bundle}"
      COMMENT "Assembling ${display_name}.vst3 bundle"
      VERBATIM
    )
    if(LOOPY_VST3_DEV_INSTALL)
      add_custom_command(TARGET ${target} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "$ENV{HOME}/Library/Audio/Plug-Ins/VST3"
        COMMAND ${CMAKE_COMMAND} -E rm -rf
          "$ENV{HOME}/Library/Audio/Plug-Ins/VST3/${display_name}.vst3"
        COMMAND ${CMAKE_COMMAND} -E copy_directory
          "${bundle}" "$ENV{HOME}/Library/Audio/Plug-Ins/VST3/${display_name}.vst3"
        COMMENT "Installing ${display_name}.vst3 to ~/Library/Audio/Plug-Ins/VST3"
        VERBATIM
      )
    endif()
  elseif(WIN32)
    # Windows bundle folder: Contents/x86_64-win/<name>.vst3 (the DLL). No
    # codesign / Info.plist / PkgInfo. (Part 13 — not reached until the guard
    # above is lifted.)
    set(module_in_bundle "${bundle}/Contents/x86_64-win/${display_name}.vst3")
    add_custom_command(TARGET ${target} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E make_directory "${bundle}/Contents/x86_64-win"
      COMMAND ${CMAKE_COMMAND} -E copy
        "$<TARGET_FILE:${target}>" "${module_in_bundle}"
      COMMENT "Assembling ${display_name}.vst3 bundle"
      VERBATIM
    )
  else()
    # Linux bundle folder: Contents/x86_64-linux/<name>.so. (Part 14.)
    set(module_in_bundle "${bundle}/Contents/x86_64-linux/${display_name}.so")
    add_custom_command(TARGET ${target} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E make_directory "${bundle}/Contents/x86_64-linux"
      COMMAND ${CMAKE_COMMAND} -E copy
        "$<TARGET_FILE:${target}>" "${module_in_bundle}"
      COMMENT "Assembling ${display_name}.vst3 bundle"
      VERBATIM
    )
  endif()
  # Required load smoke: dlopen/LoadLibrary the ASSEMBLED module and resolve
  # GetPluginFactory — the only check that exercises the export table + the
  # per-OS bundle layout (the parity tests link factory.cpp in-process).
  add_test(NAME vst3_${target}_load COMMAND load_smoke "${module_in_bundle}")
endfunction()

# ---------------------------------------------------------------------------
# Tests (CTest) — the single build definition for the plugin test suite.
# Migrated verbatim (same sources, includes, link sets) from the Darwin-gated
# vst3 block that used to live in packages/loopy_engine/src/test/
# run_native_tests.sh; that block was removed so the two can never drift. Run
# on macOS/Windows/Linux by the vst3-plugins-* CI jobs. Configure with
# -DCMAKE_BUILD_TYPE=Debug to match the shell harness's DEVELOPMENT=1.
# ---------------------------------------------------------------------------
enable_testing()

# The load smoke helper (registered per-plugin by loopy_vst3_add_bundle above).
add_executable(load_smoke "${CMAKE_CURRENT_SOURCE_DIR}/test/load_smoke.cpp")
if(NOT WIN32 AND NOT APPLE)
  target_link_libraries(load_smoke PRIVATE ${CMAKE_DL_LIBS})
endif()

# Include dirs shared by the wrapper + parity tests (mirrors the shell recipe).
set(LOOPY_VST3_TEST_INC
  "${LOOPY_VST3_SDK_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/core"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/miniaudio"
)

# GUID-drift test: standalone — only the plugin's ids.h, no SDK link.
function(loopy_vst3_add_ids_test fx)
  add_executable(test_vst3_${fx}_ids "${fx}/test_vst3_${fx}_ids.cpp")
  target_include_directories(test_vst3_${fx}_ids PRIVATE
    "${LOOPY_VST3_SDK_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/${fx}")
  add_test(NAME vst3_${fx}_ids COMMAND test_vst3_${fx}_ids)
endfunction()

# Wrapper test: instantiates Processor/Controller directly (no factory). Needs
# MemoryStream (now in sdk_common). DEVELOPMENT/RELEASE comes from the global
# config-based define at the top of this file.
function(loopy_vst3_add_wrapper_test fx)
  add_executable(test_vst3_${fx}_wrapper
    "${fx}/test_vst3_${fx}_wrapper.cpp"
    "${fx}/processor.cpp" "${fx}/controller.cpp")
  target_include_directories(test_vst3_${fx}_wrapper PRIVATE
    ${LOOPY_VST3_TEST_INC}
    "${CMAKE_CURRENT_SOURCE_DIR}/${fx}" "${CMAKE_CURRENT_SOURCE_DIR}/test")
  target_link_libraries(test_vst3_${fx}_wrapper PRIVATE
    loopy_dsp_core core_plugin_disabled_stub sdk sdk_common)
  add_test(NAME vst3_${fx}_wrapper COMMAND test_vst3_${fx}_wrapper)
endfunction()

# Golden-parity harness: drives the real factory->createInstance->process path
# (host_harness.cpp) and diffs against fx_apply_chain. One binary per plugin —
# each factory.cpp defines a global GetPluginFactory, so they can't co-link.
# sdk already compiles pluginfactory.cpp.
function(loopy_vst3_add_parity_test fx)
  add_executable(test_vst3_${fx}_parity
    "test/host_harness.cpp" "test/test_${fx}_parity.cpp"
    "${fx}/processor.cpp" "${fx}/controller.cpp" "${fx}/factory.cpp")
  target_include_directories(test_vst3_${fx}_parity PRIVATE
    ${LOOPY_VST3_TEST_INC}
    "${CMAKE_CURRENT_SOURCE_DIR}/${fx}" "${CMAKE_CURRENT_SOURCE_DIR}/test")
  target_link_libraries(test_vst3_${fx}_parity PRIVATE
    loopy_dsp_core core_plugin_disabled_stub sdk sdk_common)
  add_test(NAME vst3_${fx}_parity COMMAND test_vst3_${fx}_parity)
endfunction()

foreach(fx delay reverb echo drive filter tremolo octaver)
  loopy_vst3_add_ids_test(${fx})
  loopy_vst3_add_parity_test(${fx})
endforeach()
# Wrapper-level tests exist only for Delay (part 2) and Reverb (part 3).
loopy_vst3_add_wrapper_test(delay)
loopy_vst3_add_wrapper_test(reverb)

# --- loopy_vst3_delay: "Loopy Delay" (part 2) -------------------------------
add_library(loopy_vst3_delay MODULE
  delay/processor.cpp
  delay/controller.cpp
  delay/factory.cpp
)
set_target_properties(loopy_vst3_delay PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  PREFIX ""
  SUFFIX "${LOOPY_VST3_MODULE_SUFFIX}"
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
  ${LOOPY_VST3_EXPORT_LINK_OPTS}
)
loopy_vst3_add_bundle(loopy_vst3_delay "Loopy Delay" "${CMAKE_CURRENT_SOURCE_DIR}/delay")

# --- loopy_vst3_reverb: "Loopy Reverb" (part 3) -----------------------------
add_library(loopy_vst3_reverb MODULE
  reverb/processor.cpp
  reverb/controller.cpp
  reverb/factory.cpp
)
set_target_properties(loopy_vst3_reverb PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  PREFIX ""
  SUFFIX "${LOOPY_VST3_MODULE_SUFFIX}"
  OUTPUT_NAME "Loopy Reverb"
)
target_include_directories(loopy_vst3_reverb PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/reverb"
)
target_link_libraries(loopy_vst3_reverb PRIVATE
  loopy_dsp_core
  core_plugin_disabled_stub
  sdk
  sdk_common
)
target_link_options(loopy_vst3_reverb PRIVATE
  ${LOOPY_VST3_EXPORT_LINK_OPTS}
)
loopy_vst3_add_bundle(loopy_vst3_reverb "Loopy Reverb" "${CMAKE_CURRENT_SOURCE_DIR}/reverb")

# --- loopy_vst3_echo: "Loopy Echo" (part 5) ---------------------------------
add_library(loopy_vst3_echo MODULE
  echo/processor.cpp
  echo/controller.cpp
  echo/factory.cpp
)
set_target_properties(loopy_vst3_echo PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  PREFIX ""
  SUFFIX "${LOOPY_VST3_MODULE_SUFFIX}"
  OUTPUT_NAME "Loopy Echo"
)
target_include_directories(loopy_vst3_echo PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/echo"
)
target_link_libraries(loopy_vst3_echo PRIVATE
  loopy_dsp_core
  core_plugin_disabled_stub
  sdk
  sdk_common
)
target_link_options(loopy_vst3_echo PRIVATE
  ${LOOPY_VST3_EXPORT_LINK_OPTS}
)
loopy_vst3_add_bundle(loopy_vst3_echo "Loopy Echo" "${CMAKE_CURRENT_SOURCE_DIR}/echo")

# --- loopy_vst3_drive: "Loopy Drive" (part 6) -------------------------------
add_library(loopy_vst3_drive MODULE
  drive/processor.cpp
  drive/controller.cpp
  drive/factory.cpp
)
set_target_properties(loopy_vst3_drive PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  PREFIX ""
  SUFFIX "${LOOPY_VST3_MODULE_SUFFIX}"
  OUTPUT_NAME "Loopy Drive"
)
target_include_directories(loopy_vst3_drive PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/drive"
)
target_link_libraries(loopy_vst3_drive PRIVATE
  loopy_dsp_core
  core_plugin_disabled_stub
  sdk
  sdk_common
)
target_link_options(loopy_vst3_drive PRIVATE
  ${LOOPY_VST3_EXPORT_LINK_OPTS}
)
loopy_vst3_add_bundle(loopy_vst3_drive "Loopy Drive" "${CMAKE_CURRENT_SOURCE_DIR}/drive")

# --- loopy_vst3_filter: "Loopy Filter" (part 7) -----------------------------
add_library(loopy_vst3_filter MODULE
  filter/processor.cpp
  filter/controller.cpp
  filter/factory.cpp
)
set_target_properties(loopy_vst3_filter PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  PREFIX ""
  SUFFIX "${LOOPY_VST3_MODULE_SUFFIX}"
  OUTPUT_NAME "Loopy Filter"
)
target_include_directories(loopy_vst3_filter PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/filter"
)
target_link_libraries(loopy_vst3_filter PRIVATE
  loopy_dsp_core
  core_plugin_disabled_stub
  sdk
  sdk_common
)
target_link_options(loopy_vst3_filter PRIVATE
  ${LOOPY_VST3_EXPORT_LINK_OPTS}
)
loopy_vst3_add_bundle(loopy_vst3_filter "Loopy Filter" "${CMAKE_CURRENT_SOURCE_DIR}/filter")

# --- loopy_vst3_tremolo: "Loopy Tremolo" (part 8) ---------------------------
add_library(loopy_vst3_tremolo MODULE
  tremolo/processor.cpp
  tremolo/controller.cpp
  tremolo/factory.cpp
)
set_target_properties(loopy_vst3_tremolo PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  PREFIX ""
  SUFFIX "${LOOPY_VST3_MODULE_SUFFIX}"
  OUTPUT_NAME "Loopy Tremolo"
)
target_include_directories(loopy_vst3_tremolo PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/tremolo"
)
target_link_libraries(loopy_vst3_tremolo PRIVATE
  loopy_dsp_core
  core_plugin_disabled_stub
  sdk
  sdk_common
)
target_link_options(loopy_vst3_tremolo PRIVATE
  ${LOOPY_VST3_EXPORT_LINK_OPTS}
)
loopy_vst3_add_bundle(loopy_vst3_tremolo "Loopy Tremolo" "${CMAKE_CURRENT_SOURCE_DIR}/tremolo")

# --- loopy_vst3_octaver: "Loopy Octaver" (part 9) ---------------------------
add_library(loopy_vst3_octaver MODULE
  octaver/processor.cpp
  octaver/controller.cpp
  octaver/factory.cpp
)
set_target_properties(loopy_vst3_octaver PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  PREFIX ""
  SUFFIX "${LOOPY_VST3_MODULE_SUFFIX}"
  OUTPUT_NAME "Loopy Octaver"
)
target_include_directories(loopy_vst3_octaver PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/octaver"
)
target_link_libraries(loopy_vst3_octaver PRIVATE
  loopy_dsp_core
  core_plugin_disabled_stub
  sdk
  sdk_common
)
target_link_options(loopy_vst3_octaver PRIVATE
  ${LOOPY_VST3_EXPORT_LINK_OPTS}
)
loopy_vst3_add_bundle(loopy_vst3_octaver "Loopy Octaver" "${CMAKE_CURRENT_SOURCE_DIR}/octaver")
