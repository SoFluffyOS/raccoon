#include "secure_storage_options.h"

#include <utility>

#include "standard_codec.h"

namespace raccoon {

namespace {

constexpr char kChannel[] = "plugins.it_nomads.com/flutter_secure_storage";

// The options an unsigned process can't have: the data protection keychain
// (both plugins' spellings), an access group, iCloud sync.
bool Dropped(const std::string& key) {
  return key == "usesDataProtectionKeychain" || key == "useDataProtectionKeyChain" ||
         key == "groupId" || key == "synchronizable";
}

}  // namespace

bool RewriteSecureStorageCall(const std::string& channel, const uint8_t* data, size_t size,
                              std::vector<uint8_t>* out) {
  if (channel != kChannel) return false;
  MethodCall call;
  if (!DecodeMethodCall(data, size, &call) ||
      call.arguments.type() != CodecValue::Type::kMap) {
    return false;
  }
  std::vector<std::pair<std::string, CodecValue>> options;
  const CodecValue& given = call.arguments.Get("options");
  if (given.type() == CodecValue::Type::kMap) {
    const auto& items = given.items();
    for (size_t i = 0; i + 1 < items.size(); i += 2) {
      if (items[i].type() != CodecValue::Type::kString || Dropped(items[i].string_value())) {
        continue;
      }
      options.emplace_back(items[i].string_value(), items[i + 1]);
    }
  }
  // The plugins read their options as strings.
  options.emplace_back("usesDataProtectionKeychain", CodecValue::String("false"));
  options.emplace_back("useDataProtectionKeyChain", CodecValue::String("false"));
  options.emplace_back("synchronizable", CodecValue::String("false"));

  std::vector<std::pair<std::string, CodecValue>> arguments;
  const auto& items = call.arguments.items();
  for (size_t i = 0; i + 1 < items.size(); i += 2) {
    if (items[i].type() != CodecValue::Type::kString) return false;
    if (items[i].string_value() == "options") continue;
    arguments.emplace_back(items[i].string_value(), items[i + 1]);
  }
  arguments.emplace_back("options", CodecValue::Map(std::move(options)));

  *out = EncodeMethodCall(call.method, CodecValue::Map(std::move(arguments)));
  return true;
}

}  // namespace raccoon
