#if RACCOON_HAS_PLUGINS
// The host-neutral half of plugins.h: reading the manifest. The rest is
// plugins_linux.cc and plugins_mac.mm.
#include "plugins.h"

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <vector>

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

// A field of the helper's manifest, empty when it is missing or of another
// type: json::value would throw, and the runner with it.
std::string Str(const nlohmann::json& object, const char* key) {
  const auto found = object.find(key);
  return found != object.end() && found->is_string() ? found->get<std::string>() : "";
}

const nlohmann::json& List(const nlohmann::json& object, const char* key) {
  static const nlohmann::json kEmpty = nlohmann::json::array();
  const auto found = object.find(key);
  return found != object.end() && found->is_array() ? *found : kEmpty;
}

}  // namespace

bool PluginHost::LoadManifest(const std::string& path, std::string* error) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    *error = "cannot read " + path;
    return false;
  }
  const std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)),
                                   std::istreambuf_iterator<char>());
  // Parsed from bytes, as every other JSON in the runner: one parser in the
  // binary rather than a second for streams.
  const nlohmann::json manifest =
      nlohmann::json::parse(bytes.data(), bytes.data() + bytes.size(), nullptr, false);
  if (manifest.is_discarded()) {
    *error = path + ": not JSON";
    return false;
  }
  if (!manifest.is_object()) {
    *error = path + ": not a manifest";
    return false;
  }
  std::string unprepared;
  const bool prepared = Prepare(Str(manifest, "flutter_framework"), &unprepared);
  if (!prepared) {
    std::fprintf(stderr, "🦝 plugins: %s\n", unprepared.c_str());
  }
  for (const auto& item : List(manifest, "plugins")) {
    if (!item.is_object()) continue;
    PluginEntry entry;
    entry.name = Str(item, "name");
    entry.library = Str(item, "library");
    entry.symbol = Str(item, "symbol");
    entry.plugin_class = Str(item, "class");
    entry.module = Str(item, "module");
    const auto ffi = item.find("ffi");
    entry.ffi = ffi != item.end() && ffi->is_boolean() && ffi->get<bool>();
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
  for (const auto& item : List(manifest, "status")) {
    if (!item.is_object()) continue;
    statuses_.push_back({Str(item, "name"), Str(item, "state"), Str(item, "detail")});
  }
  return true;
}

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS
