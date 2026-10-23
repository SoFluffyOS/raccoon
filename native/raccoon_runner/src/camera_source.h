#pragma once

// A picture the camera shows in place of its test pattern: a PNG or JPEG,
// decoded once, then fitted to each camera's size.

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace raccoon {

struct CameraPicture {
  size_t width = 0;
  size_t height = 0;
  // Rows of width * 4 bytes, blue first.
  std::vector<uint8_t> bgra;
};

// Decodes the PNG or JPEG at |path|, UTF-8; false with |error| set when
// there is none or it does not decode.
bool LoadCameraPicture(const std::string& path, CameraPicture* picture, std::string* error);

// |picture| filling |width| x |height|: scaled to cover it, centred, the
// overflow cropped, as a camera's sensor crops to its preset.
std::vector<uint8_t> FitCameraPicture(const CameraPicture& picture, size_t width,
                                      size_t height);

}  // namespace raccoon
