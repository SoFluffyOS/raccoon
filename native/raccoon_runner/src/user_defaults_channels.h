#pragma once

// shared_preferences_foundation's Pigeon channels, answered by the runner.
//
// On a Mac the app runs on the host's Dart VM, so Platform.isMacOS holds and
// shared_preferences picks its macOS implementation, which talks to
// NSUserDefaults through these channels; the runner loads no plugin's native
// code, and an unanswered call throws (Wonderous loads its settings this way
// in its bootstrap, before its first frame). Both APIs are served: the legacy
// one behind SharedPreferences and the newer one behind
// SharedPreferencesAsync, with a store per suite name. Values persist to one
// file, written in StandardMessageCodec's own encoding, when the runner has a
// data directory; otherwise they live as long as the runner.

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "standard_codec.h"

namespace raccoon {

class UserDefaultsChannels {
 public:
  // The file the values persist to; empty keeps them in memory.
  void SetStorePath(std::string path) { path_ = std::move(path); }

  // Answers a message on one of the plugin's channels into |reply| and
  // returns true; returns false for any other channel.
  bool Handle(const std::string& channel, const uint8_t* data, size_t size,
              std::vector<uint8_t>* reply);

 private:
  using Store = std::map<std::string, CodecValue>;

  CodecValue Legacy(const std::string& method,
                    const std::vector<CodecValue>& args, bool* known);
  CodecValue Async(const std::string& method,
                   const std::vector<CodecValue>& args, bool* known);
  // The store for a SharedPreferencesPigeonOptions value ([suiteName]).
  Store& Suite(const CodecValue& options);
  void Load();
  void Save() const;

  std::string path_;
  bool loaded_ = false;
  // By suite name; "" is the standard defaults, which the legacy API uses.
  std::map<std::string, Store> suites_;
};

}  // namespace raccoon
