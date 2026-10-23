#if defined(_WIN32)
// The Windows half of host_settings.h: what Flutter's Windows embedding
// reads for its apps.
#include "host_settings.h"

#include <windows.h>

#include <string>
#include <vector>

namespace raccoon {

namespace {

std::string Utf8(const wchar_t* text) {
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string out(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), size, nullptr, nullptr);
  return out;
}

}  // namespace

HostSettings ReadHostSettings() {
  HostSettings settings;
  // The user's display languages, most wanted first: "en-US\0vi-VN\0\0".
  ULONG count = 0;
  ULONG length = 0;
  if (GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, nullptr, &length) && length > 0) {
    std::vector<wchar_t> names(length);
    if (GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, names.data(), &length)) {
      for (const wchar_t* name = names.data(); *name != L'\0'; name += wcslen(name) + 1) {
        HostLocale locale = ParseLocale(Utf8(name));
        if (!locale.language.empty()) settings.locales.push_back(locale);
      }
    }
  }
  // Apps are dark when "Choose your app mode" is: AppsUseLightTheme is 0.
  DWORD light = 1;
  DWORD size = sizeof(light);
  if (RegGetValueW(HKEY_CURRENT_USER,
                   L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                   L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light,
                   &size) == ERROR_SUCCESS) {
    settings.dark = light == 0;
  }
  // The user's time format: an H is a 24-hour clock, an h a 12-hour one.
  wchar_t format[80] = {};
  if (GetLocaleInfoEx(LOCALE_NAME_USER_DEFAULT, LOCALE_STIMEFORMAT, format, 80) > 0) {
    settings.always_24_hour = wcschr(format, L'H') != nullptr;
  }
  return settings;
}

}  // namespace raccoon

#endif  // _WIN32
