// load_smoke.cpp — CI load smoke for an assembled Loopy FX .vst3.
//
// The parity/wrapper tests link the plugin's TUs (factory/processor) directly
// and run the factory IN-PROCESS, so they never exercise the built, exported
// module or the per-OS bundle layout. This test does: it dlopen()s
// (LoadLibrary on Windows) the module binary inside an assembled bundle and
// resolves the exported `GetPluginFactory`, then calls it and asserts the
// returned factory is non-null. That proves the export table (macexport.exp on
// macOS / SMTG_EXPORT_SYMBOL on Windows+Linux) and the bundle path are intact.
//
// argv[1] = absolute path to the module binary inside the .vst3 bundle.
#include <cstdio>

#if defined(_WIN32)
#  include <windows.h>
#else
#  include <dlfcn.h>
#endif

namespace {
using GetFactoryFn = void* (*)();
}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: load_smoke <module-binary-path>\n");
    return 2;
  }
  const char* path = argv[1];

#if defined(_WIN32)
  HMODULE handle = ::LoadLibraryA(path);
  if (handle == nullptr) {
    std::fprintf(stderr, "LoadLibrary failed for %s (err %lu)\n", path,
                 static_cast<unsigned long>(::GetLastError()));
    return 1;
  }
  auto* sym = reinterpret_cast<GetFactoryFn>(
      reinterpret_cast<void*>(::GetProcAddress(handle, "GetPluginFactory")));
#else
  void* handle = ::dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (handle == nullptr) {
    std::fprintf(stderr, "dlopen failed for %s: %s\n", path, ::dlerror());
    return 1;
  }
  auto* sym = reinterpret_cast<GetFactoryFn>(::dlsym(handle, "GetPluginFactory"));
#endif

  if (sym == nullptr) {
    std::fprintf(stderr, "GetPluginFactory is not exported by %s\n", path);
    return 1;
  }
  void* factory = sym();
  if (factory == nullptr) {
    std::fprintf(stderr, "GetPluginFactory returned null for %s\n", path);
    return 1;
  }
  std::printf("OK: %s exports a non-null plugin factory\n", path);
  return 0;
}
