#include "host_settings.h"

#include <cctype>
#include <cstdlib>

namespace raccoon {

namespace {

// |text| cut at each |separator|, empty pieces kept: no string stream in
// the binary for it.
std::vector<std::string> Split(const std::string& text, char separator) {
  std::vector<std::string> pieces;
  size_t start = 0;
  for (size_t end; (end = text.find(separator, start)) != std::string::npos;
       start = end + 1) {
    pieces.push_back(text.substr(start, end - start));
  }
  pieces.push_back(text.substr(start));
  return pieces;
}

}  // namespace

HostLocale ParseLocale(const std::string& tag) {
  // The encoding and modifier of a POSIX locale say nothing about language.
  std::string name = tag.substr(0, tag.find_first_of(".@"));
  HostLocale locale;
  if (name.empty() || name == "C" || name == "POSIX") return locale;
  const std::vector<std::string> parts =
      Split(name, name.find('-') != std::string::npos ? '-' : '_');
  locale.language = parts[0];
  for (char& c : locale.language) {
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  }
  for (size_t i = 1; i < parts.size(); ++i) {
    std::string piece = parts[i];
    if (piece.size() == 4 && locale.script.empty() && locale.country.empty()) {
      // A script: one capital, then lower case.
      for (char& c : piece) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
      piece[0] = static_cast<char>(std::toupper(static_cast<unsigned char>(piece[0])));
      locale.script = piece;
    } else if ((piece.size() == 2 || piece.size() == 3) && locale.country.empty()) {
      for (char& c : piece) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
      locale.country = piece;
    }
  }
  return locale;
}

#if !defined(__APPLE__) && !defined(_WIN32)
HostSettings ReadHostSettings() {
  HostSettings settings;
  // LANGUAGE is a preference list; the others name one locale, in the order
  // the C library would pick it.
  if (const char* list = std::getenv("LANGUAGE"); list != nullptr && *list != '\0') {
    for (const std::string& tag : Split(list, ':')) {
      HostLocale locale = ParseLocale(tag);
      if (!locale.language.empty()) settings.locales.push_back(locale);
    }
  }
  if (settings.locales.empty()) {
    for (const char* variable : {"LC_ALL", "LC_MESSAGES", "LANG"}) {
      const char* value = std::getenv(variable);
      if (value == nullptr || *value == '\0') continue;
      HostLocale locale = ParseLocale(value);
      if (!locale.language.empty()) settings.locales.push_back(locale);
      break;
    }
  }
  return settings;
}
#endif

}  // namespace raccoon
