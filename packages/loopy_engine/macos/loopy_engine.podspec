#
# loopy_engine — macOS FFI plugin pod.
# Compiles the native engine sources from ../src directly into the plugin
# framework and links the CoreAudio stack used by miniaudio.
#
Pod::Spec.new do |s|
  s.name             = 'loopy_engine'
  s.version          = '0.1.0'
  s.summary          = 'Native low-latency duplex audio engine for Loopy.'
  s.description      = <<-DESC
A hand-written miniaudio-based looping engine exposed to Dart over FFI.
                       DESC
  s.homepage         = 'https://github.com/loopy-dev/loopy'
  s.license          = { :type => 'GPL-3.0-or-later', :file => '../LICENSE' }
  s.author           = { 'Loopy' => 'dev@loopy.dev' }
  s.source           = { :path => '.' }

  # CocoaPods does not support source_files outside the podspec directory, so
  # the shared C engine lives under ../src and is pulled in via forwarder
  # translation units in Classes/ that relatively #include it. The real headers
  # are found through HEADER_SEARCH_PATHS below.
  s.source_files     = 'Classes/**/*'

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.14'
  # CoreMIDI backs the native MIDI-input seam (midi_backend_apple.c); AppKit +
  # Foundation back the host-owned plugin editor window (part 6,
  # native_window_controller.mm).
  s.frameworks = 'CoreAudio', 'AudioToolbox', 'AudioUnit', 'CoreFoundation', 'CoreMIDI', 'AppKit', 'Foundation'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Build as a dynamic library so the produced framework binary is a loadable
    # Mach-O dylib. Flutter/CocoaPods default plugin frameworks to static
    # (MACH_O_TYPE=staticlib); that works for normal plugins (reached via the
    # registrant) but breaks FFI plugins. A static framework's binary is an ar
    # archive that dlopen cannot load, and its symbols get dead-stripped since
    # nothing references them at link time.
    #
    # The Dart side never opens the framework by path: _openLibrary() in
    # native_audio_engine.dart uses DynamicLibrary.process() (dlopen(NULL)
    # semantics) to resolve symbols from the host process's global namespace.
    # That only works because MACH_O_TYPE=mh_dylib makes this framework's
    # binary a real dylib whose symbols are dynamically loaded and exported
    # into that global namespace at launch, instead of being buried in a
    # static archive.
    'MACH_O_TYPE' => 'mh_dylib',
    'GCC_C_LANGUAGE_STANDARD' => 'gnu11',
    # The plugin include-probe (Classes/plugin_probe.cpp -> ../../src/host) is
    # C++; the VST3 SDK (3.8) needs C++17. Only the C++ TU is affected.
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    # The vendored VST3/CLAP SDK roots are added so the probe's root-relative
    # cross-includes ("pluginterfaces/base/...", <clap/entry.h>) resolve.
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../src/core" "$(PODS_TARGET_SRCROOT)/../src/midi" "$(PODS_TARGET_SRCROOT)/../src/miniaudio" "$(PODS_TARGET_SRCROOT)/../third_party/vst3sdk" "$(PODS_TARGET_SRCROOT)/../third_party/clap/include"',
    # Activate the plugin include-probe on macOS (default ON here; the
    # Windows/Linux CMake build leaves it OFF until parts 8–9).
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) LOOPY_ENABLE_PLUGINS=1',
  }
end
