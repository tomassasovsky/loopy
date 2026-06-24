// VST3 plugin scan backend.
//
// macOS implementation: walk the standard VST3 install locations, load each
// .vst3 bundle via CoreFoundation, and enumerate its audio-effect classes
// through IPluginFactory. Only the pluginterfaces IIDs are linked (vendored
// coreiids.cpp) — no base/public.sdk hosting layer is needed just to read class
// metadata. Loading a class into the audio graph lands in part 3.

#if defined(LOOPY_ENABLE_PLUGINS) && defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <sys/stat.h>

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"  // kVstAudioEffectClass
#include "plugin_host.h"

using Steinberg::IPluginFactory;
using Steinberg::IPluginFactory2;
using Steinberg::PClassInfo;
using Steinberg::PClassInfo2;
using Steinberg::TUID;

namespace {

// macOS VST3 bundle entry points (see ipluginbase.h "bundleEntry").
typedef bool (*BundleEntryFunc)(CFBundleRef);
typedef bool (*BundleExitFunc)();
typedef IPluginFactory* (*GetFactoryFunc)();

std::string homeDir() {
  const char* home = std::getenv("HOME");
  return home ? std::string(home) : std::string();
}

// The standard macOS VST3 search locations: user then system (scan order
// determines duplicate-id precedence — user wins — handled in the Dart catalog).
std::vector<std::string> searchDirs() {
  std::vector<std::string> dirs;
  const std::string home = homeDir();
  if (!home.empty()) dirs.push_back(home + "/Library/Audio/Plug-Ins/VST3");
  dirs.push_back("/Library/Audio/Plug-Ins/VST3");
  return dirs;
}

bool hasSuffix(const std::string& s, const char* suffix) {
  const size_t n = std::string(suffix).size();
  return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

std::string baseName(const std::string& path) {
  const size_t slash = path.find_last_of('/');
  return slash == std::string::npos ? path : path.substr(slash + 1);
}

// Recursively collect *.vst3 bundle paths under `dir`, without descending into a
// bundle (a directory whose name ends in .vst3 is itself a candidate leaf).
void collect(const std::string& dir, std::vector<std::string>& out, int depth) {
  if (depth > 8) return;  // guard against pathological symlink loops
  DIR* d = opendir(dir.c_str());
  if (!d) return;
  for (struct dirent* e = readdir(d); e; e = readdir(d)) {
    const std::string name = e->d_name;
    if (name == "." || name == "..") continue;
    const std::string path = dir + "/" + name;
    if (hasSuffix(name, ".vst3")) {
      out.push_back(path);
      continue;  // a .vst3 is a bundle leaf — do not descend
    }
    struct stat st;
    if (stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
      collect(path, out, depth + 1);
    }
  }
  closedir(d);
}

std::string hexTuid(const TUID cid) {
  static const char* kHex = "0123456789ABCDEF";
  std::string s;
  s.reserve(32);
  for (int i = 0; i < 16; ++i) {
    const unsigned char b = static_cast<unsigned char>(cid[i]);
    s.push_back(kHex[b >> 4]);
    s.push_back(kHex[b & 0xF]);
  }
  return s;
}

// Loads one bundle and emits a descriptor per audio-effect class, or a single
// failed entry (empty id) if the bundle cannot be loaded / queried.
void scanBundle(const std::string& path, loopy::ScanSink& sink) {
  sink.candidateScanned();

  auto fail = [&] {
    loopy::PluginDescriptor d;
    d.format = loopy::PluginFormat::vst3;
    d.name = baseName(path);
    d.path = path;
    sink.add(d);  // empty id == failed
  };

  CFStringRef cfPath = CFStringCreateWithCString(
      kCFAllocatorDefault, path.c_str(), kCFStringEncodingUTF8);
  if (!cfPath) return fail();
  CFURLRef url = CFURLCreateWithFileSystemPath(
      kCFAllocatorDefault, cfPath, kCFURLPOSIXPathStyle, true);
  CFRelease(cfPath);
  if (!url) return fail();
  CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, url);
  CFRelease(url);
  if (!bundle) return fail();

  auto entry = reinterpret_cast<BundleEntryFunc>(
      CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleEntry")));
  auto getFactory = reinterpret_cast<GetFactoryFunc>(
      CFBundleGetFunctionPointerForName(bundle, CFSTR("GetPluginFactory")));
  auto exit = reinterpret_cast<BundleExitFunc>(
      CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleExit")));

  if (!getFactory || (entry && !entry(bundle))) {
    CFRelease(bundle);
    return fail();
  }

  IPluginFactory* factory = getFactory();
  if (!factory) {
    if (exit) exit();
    CFRelease(bundle);
    return fail();
  }

  IPluginFactory2* factory2 = nullptr;
  factory->queryInterface(IPluginFactory2::iid,
                          reinterpret_cast<void**>(&factory2));

  const int32_t count = factory->countClasses();
  for (int32_t i = 0; i < count; ++i) {
    if (factory2) {
      PClassInfo2 info;
      if (factory2->getClassInfo2(i, &info) != Steinberg::kResultOk) continue;
      if (std::string(info.category) != kVstAudioEffectClass) continue;
      loopy::PluginDescriptor d;
      d.format = loopy::PluginFormat::vst3;
      d.id = hexTuid(info.cid);
      d.name = info.name;
      d.vendor = info.vendor;
      d.path = path;
      d.version = loopy::parseVersion(info.version);
      sink.add(d);
    } else {
      PClassInfo info;
      if (factory->getClassInfo(i, &info) != Steinberg::kResultOk) continue;
      if (std::string(info.category) != kVstAudioEffectClass) continue;
      loopy::PluginDescriptor d;
      d.format = loopy::PluginFormat::vst3;
      d.id = hexTuid(info.cid);
      d.name = info.name;
      d.path = path;
      sink.add(d);
    }
  }

  if (factory2) factory2->release();
  factory->release();
  if (exit) exit();
  CFRelease(bundle);
}

}  // namespace

namespace loopy {

void scanVst3(ScanSink& sink) {
  std::vector<std::string> bundles;
  for (const std::string& dir : searchDirs()) collect(dir, bundles, 0);
  for (size_t i = 0; i < bundles.size(); ++i) sink.candidateDiscovered();
  for (const std::string& path : bundles) {
    if (sink.cancelled()) return;
    scanBundle(path, sink);
  }
}

}  // namespace loopy

#elif defined(LOOPY_ENABLE_PLUGINS)

// Non-Apple plugin build: the VST3 scan lands with the Windows/Linux ports
// (parts 8–9). Empty so the symbol resolves.
#include "plugin_host.h"
namespace loopy {
void scanVst3(ScanSink&) {}
}  // namespace loopy

#endif  // LOOPY_ENABLE_PLUGINS && __APPLE__
