#if RACCOON_HAS_PLUGINS
// The host-neutral half of plugins.h: reading the manifest. The rest is
// plugins_linux.cc and plugins_mac.mm.
#include "plugins.h"

#include <cstdio>
#include <fstream>
#include <nlohmann/json.hpp>

namespace raccoon {

namespace {

// The loader's reason, short, for the log; the report keeps it whole.
// macOS's dlopen error repeats the path and lists every place it tried:
// what matters is after "dlopen(...): ", up to the line's end.
std::string ShortReason(const std::string& why) {
  std::string reason = why;
  const size_t dlopen = reason.find("dlopen(");
  const size_t colon = dlopen == std::string::npos ? std::string::npos : reason.find("): ", dlopen);
  if (colon != std::string::npos) reason = reason.substr(colon + 3);
  const size_t end = reason.find('\n');
  if (end != std::string::npos) reason.resize(end);
  return reason;
}

}  // namespace

bool PluginHost::LoadManifest(const std::string& path, std::string* error) {
  std::ifstream in(path);
  if (!in) {
    *error = "cannot read " + path;
    return false;
  }
  nlohmann::json manifest;
  try {
    in >> manifest;
  } catch (const std::exception& e) {
    *error = path + ": " + e.what();
    return false;
  }
  std::string unprepared;
  const bool prepared = Prepare(manifest.value("flutter_framework", ""), &unprepared);
  if (!prepared) {
    std::fprintf(stderr, "🦝 plugins: %s\n", unprepared.c_str());
  }
  for (const auto& item : manifest.value("plugins", nlohmann::json::array())) {
    PluginEntry entry;
    entry.name = item.value("name", "");
    entry.library = item.value("library", "");
    entry.symbol = item.value("symbol", "");
    entry.plugin_class = item.value("class", "");
    entry.module = item.value("module", "");
    entry.ffi = item.value("ffi", false);
    std::string why = unprepared;
    if (prepared && Load(entry, &why)) {
      std::fprintf(stderr, "🦝 plugin %s loaded\n", entry.name.c_str());
      statuses_.push_back({entry.name, "loaded", ""});
    } else {
      std::fprintf(stderr, "🦝 plugin %s not loaded\n     %s\n", entry.name.c_str(),
                   ShortReason(why).c_str());
      statuses_.push_back({entry.name, "failed", why});
    }
  }
  // The ones that never got as far as a library: the helper's word.
  for (const auto& item : manifest.value("status", nlohmann::json::array())) {
    statuses_.push_back({item.value("name", ""), item.value("state", ""),
                         item.value("detail", "")});
  }
  return true;
}

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS
