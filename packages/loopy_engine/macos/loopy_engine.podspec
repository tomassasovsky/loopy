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
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Loopy' => 'dev@loopy.dev' }
  s.source           = { :path => '.' }

  # Compile the C engine + the miniaudio implementation TU.
  s.source_files     = '../src/*.{c,h}', '../src/miniaudio/miniaudio.h'
  s.public_header_files = '../src/loopy_engine_api.h'

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.14'
  s.frameworks = 'CoreAudio', 'AudioToolbox', 'AudioUnit', 'CoreFoundation'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'GCC_C_LANGUAGE_STANDARD' => 'gnu11',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../src" "$(PODS_TARGET_SRCROOT)/../src/miniaudio"',
  }
end
