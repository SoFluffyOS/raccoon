#include "user_defaults_channels.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <utility>

namespace raccoon {

namespace {

constexpr char kPrefix[] = "dev.flutter.pigeon.shared_preferences_foundation.";
constexpr char kLegacyApi[] = "LegacyUserDefaultsApi";
constexpr char kAsyncApi[] = "UserDefaultsApi";

// Pigeon's replies: [result] on success, [code, message, details] on error.
std::vector<uint8_t> Reply(CodecValue result) {
  std::vector<CodecValue> items;
  items.push_back(std::move(result));
  return EncodeValue(CodecValue::List(std::move(items)));
}

std::vector<uint8_t> ErrorReply(const std::string& code,
                                const std::string& message) {
  return EncodeValue(CodecValue::List(
      {CodecValue::String(code), CodecValue::String(message), CodecValue()}));
}

const CodecValue& Arg(const std::vector<CodecValue>& args, size_t index) {
  static const CodecValue null_value;
  return index < args.size() ? args[index] : null_value;
}

// A null allow list allows every key.
bool Allowed(const CodecValue& allow_list, const std::string& key) {
  if (allow_list.type() != CodecValue::Type::kList) return true;
  for (const CodecValue& item : allow_list.items()) {
    if (item.type() == CodecValue::Type::kString && item.string_value() == key) {
      return true;
    }
  }
  return false;
}

bool HasPrefix(const std::string& key, const std::string& prefix) {
  return key.compare(0, prefix.size(), prefix) == 0;
}

CodecValue MapOf(const std::map<std::string, CodecValue>& entries) {
  std::vector<std::pair<std::string, CodecValue>> out(entries.begin(),
                                                      entries.end());
  return CodecValue::Map(std::move(out));
}

}  // namespace

bool UserDefaultsChannels::Handle(const std::string& channel,
                                  const uint8_t* data, size_t size,
                                  std::vector<uint8_t>* reply) {
  if (!HasPrefix(channel, kPrefix)) return false;
  // <Api>.<method>, and .<suffix> when the app set a channel suffix.
  const std::string rest = channel.substr(sizeof(kPrefix) - 1);
  const size_t dot = rest.find('.');
  if (dot == std::string::npos) return false;
  const std::string api = rest.substr(0, dot);
  std::string method = rest.substr(dot + 1);
  method = method.substr(0, method.find('.'));
  if (api != kLegacyApi && api != kAsyncApi) return false;

  CodecValue message;
  if (!DecodeValue(data, size, &message) ||
      message.type() != CodecValue::Type::kList) {
    *reply = ErrorReply("bad-call", "raccoon_runner could not decode " + channel);
    return true;
  }
  if (std::getenv("RACCOON_TRACE") != nullptr) {
    std::fprintf(stderr, "raccoon_runner: shared_preferences %s.%s\n",
                 api.c_str(), method.c_str());
  }
  Load();
  bool known = false;
  CodecValue result = api == kLegacyApi ? Legacy(method, message.items(), &known)
                                        : Async(method, message.items(), &known);
  *reply = known ? Reply(std::move(result))
                 : ErrorReply("unimplemented",
                              "raccoon_runner does not serve " + channel);
  return true;
}

CodecValue UserDefaultsChannels::Legacy(const std::string& method,
                                        const std::vector<CodecValue>& args,
                                        bool* known) {
  *known = true;
  Store& store = suites_[""];
  if (method == "getAll" || method == "clear") {
    const CodecValue& prefix = Arg(args, 0);
    const std::string text =
        prefix.type() == CodecValue::Type::kString ? prefix.string_value() : "";
    const CodecValue& allow_list = Arg(args, 1);
    Store matching;
    for (auto it = store.begin(); it != store.end();) {
      if (HasPrefix(it->first, text) && Allowed(allow_list, it->first)) {
        if (method == "getAll") {
          matching.insert(*it);
        } else {
          it = store.erase(it);
          continue;
        }
      }
      ++it;
    }
    if (method == "getAll") return MapOf(matching);
    Save();
    return CodecValue::Bool(true);
  }
  const CodecValue& key = Arg(args, 0);
  if (key.type() != CodecValue::Type::kString) {
    *known = false;
    return CodecValue();
  }
  if (method == "remove") {
    store.erase(key.string_value());
  } else if (method == "setBool" || method == "setDouble" ||
             method == "setValue") {
    store[key.string_value()] = Arg(args, 1);
  } else {
    *known = false;
    return CodecValue();
  }
  Save();
  return CodecValue();
}

CodecValue UserDefaultsChannels::Async(const std::string& method,
                                       const std::vector<CodecValue>& args,
                                       bool* known) {
  *known = true;
  if (method == "set") {
    const CodecValue& key = Arg(args, 0);
    if (key.type() != CodecValue::Type::kString) {
      *known = false;
      return CodecValue();
    }
    Suite(Arg(args, 2))[key.string_value()] = Arg(args, 1);
    Save();
    return CodecValue();
  }
  if (method == "getValue") {
    const CodecValue& key = Arg(args, 0);
    Store& store = Suite(Arg(args, 1));
    if (key.type() != CodecValue::Type::kString) return CodecValue();
    const auto found = store.find(key.string_value());
    return found == store.end() ? CodecValue() : found->second;
  }
  const CodecValue& allow_list = Arg(args, 0);
  Store& store = Suite(Arg(args, 1));
  if (method == "getAll") {
    Store matching;
    for (const auto& entry : store) {
      if (Allowed(allow_list, entry.first)) matching.insert(entry);
    }
    return MapOf(matching);
  }
  if (method == "getKeys") {
    std::vector<CodecValue> keys;
    for (const auto& entry : store) {
      if (Allowed(allow_list, entry.first)) {
        keys.push_back(CodecValue::String(entry.first));
      }
    }
    return CodecValue::List(std::move(keys));
  }
  if (method == "clear") {
    for (auto it = store.begin(); it != store.end();) {
      it = Allowed(allow_list, it->first) ? store.erase(it) : std::next(it);
    }
    Save();
    return CodecValue();
  }
  *known = false;
  return CodecValue();
}

UserDefaultsChannels::Store& UserDefaultsChannels::Suite(
    const CodecValue& options) {
  // SharedPreferencesPigeonOptions arrives as its field list, [suiteName].
  std::string name;
  if (options.type() == CodecValue::Type::kList && !options.items().empty() &&
      options.items()[0].type() == CodecValue::Type::kString) {
    name = options.items()[0].string_value();
  }
  return suites_[name];
}

void UserDefaultsChannels::Load() {
  if (loaded_) return;
  loaded_ = true;
  if (path_.empty()) return;
  std::ifstream in(path_, std::ios::binary);
  if (!in) return;
  const std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)),
                                   std::istreambuf_iterator<char>());
  CodecValue saved;
  if (!DecodeValue(bytes.data(), bytes.size(), &saved) ||
      saved.type() != CodecValue::Type::kMap) {
    std::fprintf(stderr, "raccoon_runner: ignoring unreadable %s\n",
                 path_.c_str());
    return;
  }
  // {suite: {key: value}}; a map's items alternate keys and values.
  const std::vector<CodecValue>& suites = saved.items();
  for (size_t i = 0; i + 1 < suites.size(); i += 2) {
    Store& store = suites_[suites[i].string_value()];
    const std::vector<CodecValue>& entries = suites[i + 1].items();
    for (size_t j = 0; j + 1 < entries.size(); j += 2) {
      store[entries[j].string_value()] = entries[j + 1];
    }
  }
}

void UserDefaultsChannels::Save() const {
  if (path_.empty()) return;
  std::vector<std::pair<std::string, CodecValue>> suites;
  for (const auto& [name, store] : suites_) suites.emplace_back(name, MapOf(store));
  const std::vector<uint8_t> bytes = EncodeValue(CodecValue::Map(std::move(suites)));
  std::error_code error;
  const std::filesystem::path path(path_);
  std::filesystem::create_directories(path.parent_path(), error);
  // Write a sibling and rename it over the file, so a crash never leaves
  // half a store.
  const std::string temp = path_ + ".tmp";
  {
    std::ofstream out(temp, std::ios::binary | std::ios::trunc);
    out.write(reinterpret_cast<const char*>(bytes.data()),
              static_cast<std::streamsize>(bytes.size()));
    if (!out) {
      std::fprintf(stderr, "raccoon_runner: could not write %s\n", temp.c_str());
      return;
    }
  }
  std::filesystem::rename(temp, path, error);
  if (error) {
    std::fprintf(stderr, "raccoon_runner: could not replace %s: %s\n",
                 path_.c_str(), error.message().c_str());
  }
}

}  // namespace raccoon
