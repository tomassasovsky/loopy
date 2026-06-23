// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to
// build this package.
//
// Swift Package Manager manifest for the loopy_engine FFI plugin on macOS.
//
// This is a C target with one C++ TU (the VST3/CLAP include-probe): the shared
// engine sources live at the plugin root under ../src and are pulled in via
// forwarder translation units in Sources/loopy_engine/ (SPM, like CocoaPods,
// only compiles sources inside the package directory). The engine headers
// co-located in ../src resolve relative to each forwarded source file; the one
// exception, miniaudio.h (which lives in ../src/miniaudio/), is satisfied by a
// forwarder header in the target's include/ directory — SPM adds include/ to
// the header search path, and SPM rejects header search paths that point
// outside the package root. The vendored plugin SDKs are the other exception,
// reached via absolute -I flags computed below.
//
// The product is built as a `.dynamic` library so the engine is loaded as its
// own image at launch: this keeps the FFI-exported symbols (LE_EXPORT =
// visibility("default") + used) off the dead-strip list and resolvable at
// runtime via `DynamicLibrary.process()` from Dart. The hyphenated product name
// is required — Swift Package Manager uses it as the CFBundleIdentifier when
// linked dynamically, which cannot contain underscores.

import Foundation
import PackageDescription

// Absolute paths to the vendored VST3/CLAP SDK roots, which live at the plugin
// root under ../../third_party — OUTSIDE this SPM package, where SPM's safe
// `headerSearchPath` refuses to point. They are passed to clang as raw `-I`
// flags (see cxxSettings below), and a *relative* `-I` cannot be used: under
// xcodebuild the compiler's working directory is not the package root, and
// Flutter consumes this package through a symlink (macos/Flutter/ephemeral/
// Packages/.packages/loopy_engine), so `../..` resolves into the wrong tree.
//
// Deriving the paths from this manifest's own location, with the symlink
// resolved, yields a stable absolute path on any machine/CI without hardcoding.
private let thirdPartyDir = URL(fileURLWithPath: #filePath)
  .resolvingSymlinksInPath()
  .deletingLastPathComponent()  // macos/loopy_engine (package root)
  .deletingLastPathComponent()  // macos
  .deletingLastPathComponent()  // packages/loopy_engine (plugin root)
  .appendingPathComponent("third_party")
private let vst3IncludeDir = thirdPartyDir.appendingPathComponent("vst3sdk").path
private let clapIncludeDir = thirdPartyDir.appendingPathComponent("clap/include").path

let package = Package(
  name: "loopy_engine",
  platforms: [
    .macOS(.v10_15),
  ],
  products: [
    .library(name: "loopy-engine", type: .dynamic, targets: ["loopy_engine"]),
  ],
  targets: [
    .target(
      name: "loopy_engine",
      // The plugin include-probe (plugin_probe.cpp, forwarded from ../src/host)
      // is C++; the rest of the target stays pure C. Setting the C++ standard
      // here only affects the C++ TUs — the vendored VST3 SDK (3.8) needs C++17.
      cxxSettings: [
        // Add the vendored SDK roots (computed absolutely above) so the SDKs'
        // own root-relative cross-includes (e.g. "pluginterfaces/base/...",
        // <clap/entry.h>) resolve, matching how the real host code in later
        // parts will include them. This is a local path-based dependency, so
        // the unsafe-flags restriction that blocks versioned dependencies does
        // not apply.
        .unsafeFlags([
          "-I\(vst3IncludeDir)",
          "-I\(clapIncludeDir)",
        ]),
        // Activate the plugin include-probe on macOS (default ON here; the
        // Windows/Linux CMake build leaves it OFF until parts 8–9).
        .define("LOOPY_ENABLE_PLUGINS"),
      ],
      linkerSettings: [
        .linkedFramework("CoreAudio"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("AudioUnit"),
        .linkedFramework("CoreFoundation"),
        // CoreMIDI backs the native MIDI input seam (midi_backend_apple.c),
        // forwarded into this target alongside the engine.
        .linkedFramework("CoreMIDI"),
        // AppKit (NSWindow) + Foundation (NSString) back the host-owned plugin
        // editor window (native_window_controller.mm, part 6).
        .linkedFramework("AppKit"),
        .linkedFramework("Foundation"),
      ]
    ),
  ],
  cxxLanguageStandard: .cxx17
)
