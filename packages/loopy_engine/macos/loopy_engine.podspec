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
  # CoreMIDI backs the native MIDI-input seam (midi_backend_apple.c).
  s.frameworks = 'CoreAudio', 'AudioToolbox', 'AudioUnit', 'CoreFoundation', 'CoreMIDI'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Build as a dynamic library so the produced framework binary is a loadable
    # Mach-O dylib. Flutter/CocoaPods default plugin frameworks to static
    # (MACH_O_TYPE=staticlib); that works for normal plugins (reached via the
    # registrant) but breaks FFI plugins, whose symbols are only resolved at
    # runtime via DynamicLibrary.open('loopy_engine.framework/loopy_engine').
    # A static framework's binary is an ar archive that dlopen cannot load, and
    # its symbols get dead-stripped since nothing references them at link time.
    'MACH_O_TYPE' => 'mh_dylib',
    'GCC_C_LANGUAGE_STANDARD' => 'gnu11',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../src/core" "$(PODS_TARGET_SRCROOT)/../src/midi" "$(PODS_TARGET_SRCROOT)/../src/miniaudio"',
  }
end
