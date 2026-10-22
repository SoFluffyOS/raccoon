#if RACCOON_HAS_PLUGINS
// The host-neutral half of plugins.h: reading the manifest. The rest is
// plugins_linux.cc and plugins_mac.mm.
#include "plugins.h"

#include <cstdio>
#include <fstream>
#include <nlohmann/json.hpp>

namespace raccoon {

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
    std::fprintf(stderr, "raccoon_runner: plugins: %s\n", unprepared.c_str());
  }
  for (const auto& item : manifest.value("plugins", nlohmann::json::array())) {
    PluginEntry entry;
    entry.name = item.value("name", "");
    entry.library = item.value("library", "");
    entry.symbol = item.value("symbol", "");
    entry.plugin_class = item.value("class", "");
    entry.module = item.value("module", "");
    std::string why = unprepared;
    if (prepared && Load(entry, &why)) {
      std::fprintf(stderr, "raccoon_runner: plugin %s loaded\n", entry.name.c_str());
      statuses_.push_back({entry.name, "loaded", ""});
    } else {
      std::fprintf(stderr, "raccoon_runner: plugin %s not loaded: %s\n", entry.name.c_str(),
                   why.c_str());
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
