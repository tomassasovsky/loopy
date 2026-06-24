// CLAP plugin scan backend.
//
// macOS implementation: walk the standard CLAP install locations (plus
// $CLAP_PATH), load each .clap bundle via CoreFoundation, read the
// `clap_entry` symbol, and enumerate the plugin factory's descriptors. CLAP is
// a header-only C ABI, so nothing is linked. Instantiating a plugin lands in
// part 3.

#if defined(LOOPY_ENABLE_PLUGINS) && defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <sys/stat.h>

#include <cstdlib>
#include <string>
#include <vector>

#include <clap/clap.h>

#include "plugin_host.h"

namespace {

std::string env(const char* name) {
  const char* v = std::getenv(name);
  return v ? std::string(v) : std::string();
}

bool hasSuffix(const std::string& s, const char* suffix) {
  const size_t n = std::string(suffix).size();
  return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

std::string baseName(const std::string& path) {
  const size_t slash = path.find_last_of('/');
  return slash == std::string::npos ? path : path.substr(slash + 1);
}

// Standard macOS CLAP locations: user, then system, then any $CLAP_PATH entries
// (colon-separated). Scan order sets duplicate-id precedence (user wins).
std::vector<std::string> searchDirs() {
  std::vector<std::string> dirs;
  const std::string home = env("HOME");
  if (!home.empty()) dirs.push_back(home + "/Library/Audio/Plug-Ins/CLAP");
  dirs.push_back("/Library/Audio/Plug-Ins/CLAP");
  const std::string extra = env("CLAP_PATH");
  size_t start = 0;
  while (start < extra.size()) {
    const size_t colon = extra.find(':', start);
    const size_t end = colon == std::string::npos ? extra.size() : colon;
    if (end > start) dirs.push_back(extra.substr(start, end - start));
    if (colon == std::string::npos) break;
    start = colon + 1;
  }
  return dirs;
}

void collect(const std::string& dir, std::vector<std::string>& out, int depth) {
  if (depth > 8) return;
  DIR* d = opendir(dir.c_str());
  if (!d) return;
  for (struct dirent* e = readdir(d); e; e = readdir(d)) {
    const std::string name = e->d_name;
    if (name == "." || name == "..") continue;
    const std::string path = dir + "/" + name;
    if (hasSuffix(name, ".clap")) {
      out.push_back(path);
      continue;  // a .clap is a bundle leaf — do not descend
    }
    struct stat st;
    if (stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
      collect(path, out, depth + 1);
    }
  }
  closedir(d);
}

void scanFile(const std::string& path, loopy::ScanSink& sink) {
  sink.candidateScanned();

  auto fail = [&] {
    loopy::PluginDescriptor d;
    d.format = loopy::PluginFormat::clap;
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

  auto entry = reinterpret_cast<const clap_plugin_entry_t*>(
      CFBundleGetDataPointerForName(bundle, CFSTR("clap_entry")));
  if (!entry || !entry->init || !entry->init(path.c_str())) {
    CFRelease(bundle);
    return fail();
  }

  auto factory = reinterpret_cast<const clap_plugin_factory_t*>(
      entry->get_factory ? entry->get_factory(CLAP_PLUGIN_FACTORY_ID)
                         : nullptr);
  if (factory && factory->get_plugin_count && factory->get_plugin_descriptor) {
    const uint32_t count = factory->get_plugin_count(factory);
    for (uint32_t i = 0; i < count; ++i) {
      const clap_plugin_descriptor_t* info =
          factory->get_plugin_descriptor(factory, i);
      if (!info || !info->id) continue;
      loopy::PluginDescriptor d;
      d.format = loopy::PluginFormat::clap;
      d.id = info->id;
      if (info->name) d.name = info->name;
      if (info->vendor) d.vendor = info->vendor;
      d.path = path;
      if (info->version) d.version = loopy::parseVersion(info->version);
      sink.add(d);
    }
  }

  if (entry->deinit) entry->deinit();
  CFRelease(bundle);
}

}  // namespace

namespace loopy {

void scanClap(ScanSink& sink) {
  std::vector<std::string> files;
  for (const std::string& dir : searchDirs()) collect(dir, files, 0);
  for (size_t i = 0; i < files.size(); ++i) sink.candidateDiscovered();
  for (const std::string& path : files) {
    if (sink.cancelled()) return;
    scanFile(path, sink);
  }
}

}  // namespace loopy

#elif defined(LOOPY_ENABLE_PLUGINS) && defined(_WIN32)

// Windows implementation: walk the standard CLAP install locations (plus
// $CLAP_PATH), load each .clap DLL via LoadLibrary, read the exported `clap_entry`
// data symbol, and enumerate the plugin factory's descriptors — the same factory
// read as macOS, only the directory walk and module load differ (umbrella
// D-SCAN, Windows paths).

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <string>
#include <vector>

#include <clap/clap.h>

#include "plugin_host.h"

namespace {

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

// Standard Windows CLAP locations: system Common Files, the per-user path, then
// any $CLAP_PATH entries (semicolon-separated). Scan order sets duplicate-id
// precedence (user wins).
std::vector<std::wstring> searchDirs() {
  std::vector<std::wstring> dirs;
  const std::wstring common = envW(L"COMMONPROGRAMFILES");
  if (!common.empty()) dirs.push_back(common + L"\\CLAP");
  const std::wstring local = envW(L"LOCALAPPDATA");
  if (!local.empty()) dirs.push_back(local + L"\\Programs\\Common\\CLAP");
  const std::wstring extra = envW(L"CLAP_PATH");
  size_t start = 0;
  while (start < extra.size()) {
    const size_t sep = extra.find(L';', start);
    const size_t end = sep == std::wstring::npos ? extra.size() : sep;
    if (end > start) dirs.push_back(extra.substr(start, end - start));
    if (sep == std::wstring::npos) break;
    start = sep + 1;
  }
  return dirs;
}

void collect(const std::wstring& dir, std::vector<std::wstring>& out, int depth) {
  if (depth > 8) return;
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
  if (h == INVALID_HANDLE_VALUE) return;
  do {
    const std::wstring name = fd.cFileName;
    if (name == L"." || name == L"..") continue;
    const std::wstring path = dir + L"\\" + name;
    if (hasSuffixW(name, L".clap")) {
      out.push_back(path);  // a .clap is a leaf — do not descend
      continue;
    }
    if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      collect(path, out, depth + 1);
    }
  } while (FindNextFileW(h, &fd));
  FindClose(h);
}

void scanFile(const std::wstring& path, loopy::ScanSink& sink) {
  sink.candidateScanned();
  const std::string pathUtf8 = narrow(path);

  auto fail = [&] {
    loopy::PluginDescriptor d;
    d.format = loopy::PluginFormat::clap;
    d.name = narrow(baseNameW(path));
    d.path = pathUtf8;
    sink.add(d);  // empty id == failed
  };

  HMODULE dll =
      LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (!dll) return fail();

  auto entry = reinterpret_cast<const clap_plugin_entry_t*>(
      GetProcAddress(dll, "clap_entry"));
  if (!entry || !entry->init || !entry->init(pathUtf8.c_str())) {
    FreeLibrary(dll);
    return fail();
  }

  auto factory = reinterpret_cast<const clap_plugin_factory_t*>(
      entry->get_factory ? entry->get_factory(CLAP_PLUGIN_FACTORY_ID)
                         : nullptr);
  if (factory && factory->get_plugin_count && factory->get_plugin_descriptor) {
    const uint32_t count = factory->get_plugin_count(factory);
    for (uint32_t i = 0; i < count; ++i) {
      const clap_plugin_descriptor_t* info =
          factory->get_plugin_descriptor(factory, i);
      if (!info || !info->id) continue;
      loopy::PluginDescriptor d;
      d.format = loopy::PluginFormat::clap;
      d.id = info->id;
      if (info->name) d.name = info->name;
      if (info->vendor) d.vendor = info->vendor;
      d.path = pathUtf8;
      if (info->version) d.version = loopy::parseVersion(info->version);
      sink.add(d);
    }
  }

  if (entry->deinit) entry->deinit();
  FreeLibrary(dll);
}

}  // namespace

namespace loopy {

void scanClap(ScanSink& sink) {
  std::vector<std::wstring> files;
  for (const std::wstring& dir : searchDirs()) collect(dir, files, 0);
  for (size_t i = 0; i < files.size(); ++i) sink.candidateDiscovered();
  for (const std::wstring& path : files) {
    if (sink.cancelled()) return;
    scanFile(path, sink);
  }
}

}  // namespace loopy

#elif defined(LOOPY_ENABLE_PLUGINS)

// Non-Apple, non-Windows plugin build: the CLAP scan lands with the Linux port
// (part 9). Empty so the symbol resolves.
#include "plugin_host.h"
namespace loopy {
void scanClap(ScanSink&) {}
}  // namespace loopy

#endif  // LOOPY_ENABLE_PLUGINS && __APPLE__
