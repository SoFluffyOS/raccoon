#pragma once
// The platform's key code for a physical key, as a legacy key message
// carries it: macOS's keyCode, Linux's (XKB) and Windows' scanCode. The
// framework takes the message's physical key from it.

#include <cstddef>
#include <cstdint>

namespace raccoon {

// The code for |physical|, a USB HID usage as Flutter names physical keys.
// A key the platform's map has no code for keeps its usage, past every
// code there, so the framework still tells such keys apart.
uint64_t PlatformKeyCode(uint64_t physical);

}  // namespace raccoon
