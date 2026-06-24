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

#elif defined(LOOPY_ENABLE_PLUGINS) && defined(_WIN32)

// Windows implementation: walk the standard VST3 install locations, load each
// .vst3 module via LoadLibrary (resolving a bundle directory to its inner
// Contents\x86_64-win DLL), and enumerate its audio-effect classes through
// IPluginFactory — the same class-metadata read as macOS, only the directory
// walk and module load differ (umbrella D-SCAN, Windows paths).

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <cstdint>
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

// VST3 Windows module entry points (factory.h "GetPluginFactory"; InitDll/ExitDll
// are optional one-time init hooks).
typedef bool(PLUGIN_API* InitDllFunc)();
typedef bool(PLUGIN_API* ExitDllFunc)();
typedef IPluginFactory*(PLUGIN_API* GetFactoryFunc)();

std::string narrow(const std::wstring& w) {
  if (w.empty()) return std::string();
  const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0,
                                    nullptr, nullptr);
  if (n <= 0) return std::string();
  std::string out(static_cast<size_t>(n - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, out.data(), n, nullptr, nullptr);
  return out;
}

std::wstring envW(const wchar_t* name) {
  DWORD n = GetEnvironmentVariableW(name, nullptr, 0);
  if (n == 0) return std::wstring();
  std::wstring out(n, L'\0');
  n = GetEnvironmentVariableW(name, out.data(), n);
  out.resize(n);
  return out;
}

std::wstring baseNameW(const std::wstring& path) {
  const size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

bool hasSuffixW(const std::wstring& s, const wchar_t* suffix) {
  const std::wstring suf = suffix;
  return s.size() >= suf.size() &&
         _wcsicmp(s.c_str() + (s.size() - suf.size()), suf.c_str()) == 0;
}

// The directory holding the running executable (app-local plugin search root).
std::wstring exeDir() {
  std::wstring buf(MAX_PATH, L'\0');
  const DWORD n = GetModuleFileNameW(nullptr, buf.data(),
                                     static_cast<DWORD>(buf.size()));
  if (n == 0 || n >= buf.size()) return std::wstring();
  buf.resize(n);
  const size_t slash = buf.find_last_of(L"\\/");
  return slash == std::wstring::npos ? std::wstring() : buf.substr(0, slash);
}

// Standard Windows VST3 search locations: system Common Files, the per-user
// path, then app-local. Scan order sets duplicate-id precedence (user wins —
// reconciled in the Dart catalog).
std::vector<std::wstring> searchDirs() {
  std::vector<std::wstring> dirs;
  const std::wstring common = envW(L"COMMONPROGRAMFILES");
  if (!common.empty()) dirs.push_back(common + L"\\VST3");
  const std::wstring local = envW(L"LOCALAPPDATA");
  if (!local.empty()) dirs.push_back(local + L"\\Programs\\Common\\VST3");
  const std::wstring exe = exeDir();
  if (!exe.empty()) dirs.push_back(exe + L"\\VST3");
  return dirs;
}

// Resolves a .vst3 candidate to the loadable module path. A plain DLL file is
// itself the module; a bundle directory resolves to Contents\x86_64-win\<name>.
// Returns empty when the inner module is absent.
std::wstring resolveModule(const std::wstring& candidate, DWORD attrs) {
  if (!(attrs & FILE_ATTRIBUTE_DIRECTORY)) return candidate;
  const std::wstring inner =
      candidate + L"\\Contents\\x86_64-win\\" + baseNameW(candidate);
  return GetFileAttributesW(inner.c_str()) != INVALID_FILE_ATTRIBUTES
             ? inner
             : std::wstring();
}

// Recursively collect .vst3 candidate paths under `dir` (a .vst3 entry — file or
// bundle directory — is a leaf, never descended into).
void collect(const std::wstring& dir, std::vector<std::wstring>& out, int depth) {
  if (depth > 8) return;  // guard against pathological junction loops
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
  if (h == INVALID_HANDLE_VALUE) return;
  do {
    const std::wstring name = fd.cFileName;
    if (name == L"." || name == L"..") continue;
    const std::wstring path = dir + L"\\" + name;
    if (hasSuffixW(name, L".vst3")) {
      out.push_back(path);  // a .vst3 is a leaf — do not descend
      continue;
    }
    if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      collect(path, out, depth + 1);
    }
  } while (FindNextFileW(h, &fd));
  FindClose(h);
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

// Loads one .vst3 candidate and emits a descriptor per audio-effect class, or a
// single failed entry (empty id) if it cannot be loaded / queried. `path` is the
// loadable module path (stored on each descriptor so the host loads it directly).
void scanModule(const std::wstring& candidate, loopy::ScanSink& sink) {
  sink.candidateScanned();

  const DWORD attrs = GetFileAttributesW(candidate.c_str());
  const std::wstring module =
      attrs == INVALID_FILE_ATTRIBUTES ? std::wstring()
                                       : resolveModule(candidate, attrs);
  const std::string modUtf8 = narrow(module.empty() ? candidate : module);

  auto fail = [&] {
    loopy::PluginDescriptor d;
    d.format = loopy::PluginFormat::vst3;
    d.name = narrow(baseNameW(candidate));
    d.path = modUtf8;
    sink.add(d);  // empty id == failed
  };

  if (module.empty()) return fail();

  HMODULE dll = LoadLibraryExW(module.c_str(), nullptr,
                               LOAD_WITH_ALTERED_SEARCH_PATH);
  if (!dll) return fail();

  auto initDll = reinterpret_cast<InitDllFunc>(GetProcAddress(dll, "InitDll"));
  auto getFactory =
      reinterpret_cast<GetFactoryFunc>(GetProcAddress(dll, "GetPluginFactory"));
  auto exitDll = reinterpret_cast<ExitDllFunc>(GetProcAddress(dll, "ExitDll"));
  if (!getFactory || (initDll && !initDll())) {
    FreeLibrary(dll);
    return fail();
  }

  IPluginFactory* factory = getFactory();
  if (!factory) {
    if (exitDll) exitDll();
    FreeLibrary(dll);
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
      d.path = modUtf8;
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
      d.path = modUtf8;
      sink.add(d);
    }
  }

  if (factory2) factory2->release();
  factory->release();
  if (exitDll) exitDll();
  FreeLibrary(dll);
}

}  // namespace

namespace loopy {

void scanVst3(ScanSink& sink) {
  std::vector<std::wstring> candidates;
  for (const std::wstring& dir : searchDirs()) collect(dir, candidates, 0);
  for (size_t i = 0; i < candidates.size(); ++i) sink.candidateDiscovered();
  for (const std::wstring& path : candidates) {
    if (sink.cancelled()) return;
    scanModule(path, sink);
  }
}

}  // namespace loopy

#elif defined(LOOPY_ENABLE_PLUGINS)

// Non-Apple, non-Windows plugin build: the VST3 scan lands with the Linux port
// (part 9). Empty so the symbol resolves.
#include "plugin_host.h"
namespace loopy {
void scanVst3(ScanSink&) {}
}  // namespace loopy

#endif  // LOOPY_ENABLE_PLUGINS && __APPLE__
