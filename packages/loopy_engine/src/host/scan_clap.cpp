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

#elif defined(LOOPY_ENABLE_PLUGINS)

// Non-Apple plugin build: the CLAP scan lands with the Windows/Linux ports
// (parts 8–9). Empty so the symbol resolves.
#include "plugin_host.h"
namespace loopy {
void scanClap(ScanSink&) {}
}  // namespace loopy

#endif  // LOOPY_ENABLE_PLUGINS && __APPLE__
