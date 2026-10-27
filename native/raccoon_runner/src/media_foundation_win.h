#pragma once
#if defined(_WIN32)
#include <windows.h>

namespace raccoon {

// Whether Media Foundation is on this machine. Its libraries are loaded
// when first called, not at start (#224), and an N edition without the
// Media Feature Pack has none: a call would end the runner. The check keeps
// them loaded once found.
inline bool MediaFoundationPresent() {
  static const bool present =
      LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32) != nullptr &&
      LoadLibraryExW(L"mfreadwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32) != nullptr;
  return present;
}

}  // namespace raccoon
#endif
