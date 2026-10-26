#pragma once
// The host's locales and display settings, as a native Flutter app on it
// gets them from its embedding: the preferred languages, light or dark, and
// 24-hour time. The engine knows none of these unless told.

#include <optional>
#include <string>
#include <vector>

namespace raccoon {

struct HostLocale {
  std::string language;  // "en"
  std::string country;   // "US", or empty
  std::string script;    // "Hans", or empty
};

struct HostSettings {
  std::vector<HostLocale> locales;
  bool dark = false;
  bool always_24_hour = false;
};

// What a client says the device it shows the app as has (#193): each one
// set replaces the host's.
struct SettingsOverride {
  std::vector<HostLocale> locales;  // none: the host's
  std::optional<double> text_scale;
  std::optional<bool> dark;
  std::optional<bool> always_24_hour;
};

// The host's settings now: on macOS NSLocale's preferred languages, the
// interface style and the current locale's hour cycle; on Windows the
// preferred display languages, the app mode and the time format; on Linux
// the locales of LANGUAGE, LC_ALL, LC_MESSAGES and LANG, light, 12-hour.
HostSettings ReadHostSettings();

// "en-US", "zh-Hans-CN" or "en_US.UTF-8" in parts; an empty language for
// "C", "POSIX" or nothing usable.
HostLocale ParseLocale(const std::string& tag);

}  // namespace raccoon
