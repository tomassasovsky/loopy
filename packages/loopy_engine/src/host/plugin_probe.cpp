// Vendored-SDK include probe (part 1 of the VST3/CLAP plugin-hosting stack).
//
// This translation unit contains NO host logic. Its only job is to prove that
// the vendored VST3 and CLAP headers resolve and compile in the engine build,
// so later parts of the stack can `#include` them without re-litigating the
// build wiring. The pass/fail criterion for part 1 is "this TU compiles."
//
// It is compiled only when LOOPY_ENABLE_PLUGINS is defined — default ON for the
// macOS SPM / CocoaPods builds (see Package.swift and loopy_engine.podspec),
// and OFF for the Windows/Linux CMake builds, where plugin hosting lands in
// parts 8–9. When the flag is off this file is an empty object, exactly like
// the OS-guarded platform/MIDI seams.
//
// Include roots are supplied by the build system, not relative paths here, so
// the SDKs' own root-relative cross-includes (e.g. "pluginterfaces/base/...")
// resolve the same way the real host code will use them:
//   - VST3:  third_party/vst3sdk          -> "pluginterfaces/base/ipluginbase.h"
//   - CLAP:  third_party/clap/include     -> <clap/entry.h>

#if defined(LOOPY_ENABLE_PLUGINS)

#include "pluginterfaces/base/ipluginbase.h"  // Steinberg::IPluginFactory (VST3)
#include <clap/entry.h>                        // clap_plugin_entry (CLAP)

namespace loopy {
namespace plugin_probe {

// Take sizeof one type from each SDK so the compiler must see each as a
// COMPLETE type, not just a forward declaration — proving the headers (and
// their transitive cross-includes) actually parsed, not merely that the
// top-level file was found. Pure compile-time checks: no runtime footprint, no
// exported symbol, nothing the linker has to keep.
static_assert(sizeof(::Steinberg::IPluginFactory) > 0,
              "VST3 pluginterfaces headers must resolve and compile");
static_assert(sizeof(::clap_plugin_entry) > 0,
              "CLAP entry header must resolve and compile");

}  // namespace plugin_probe
}  // namespace loopy

#endif  // LOOPY_ENABLE_PLUGINS
