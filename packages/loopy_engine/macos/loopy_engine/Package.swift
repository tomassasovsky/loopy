// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to
// build this package.
//
// Swift Package Manager manifest for the loopy_engine FFI plugin on macOS.
//
// This is a pure-C target: the shared engine sources live at the plugin root
// under ../src and are pulled in via forwarder translation units in
// Sources/loopy_engine/ (SPM, like CocoaPods, only compiles sources inside the
// package directory). The engine headers co-located in ../src resolve relative
// to each forwarded source file; the one exception, miniaudio.h (which lives in
// ../src/miniaudio/), is satisfied by a forwarder header in the target's
// include/ directory — SPM adds include/ to the header search path, and SPM
// rejects header search paths that point outside the package root.
//
// The product is built as a `.dynamic` library so the engine is loaded as its
// own image at launch: this keeps the FFI-exported symbols (LE_EXPORT =
// visibility("default") + used) off the dead-strip list and resolvable at
// runtime via `DynamicLibrary.process()` from Dart. The hyphenated product name
// is required — Swift Package Manager uses it as the CFBundleIdentifier when
// linked dynamically, which cannot contain underscores.

import PackageDescription

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
      linkerSettings: [
        .linkedFramework("CoreAudio"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("AudioUnit"),
        .linkedFramework("CoreFoundation"),
      ]
    ),
  ]
)
