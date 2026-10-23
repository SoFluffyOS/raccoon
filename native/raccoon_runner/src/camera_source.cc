#include "camera_source.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iterator>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
// Files are read here, by a UTF-8 path, not by stb_image's fopen.
#define STBI_NO_STDIO
#include "stb_image.h"

namespace raccoon {

bool LoadCameraPicture(const std::string& path, CameraPicture* picture, std::string* error) {
  std::ifstream file(std::filesystem::u8path(path), std::ios::binary);
  if (!file) {
    *error = "cannot open it";
    return false;
  }
  const std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)),
                                   std::istreambuf_iterator<char>());
  int width = 0;
  int height = 0;
  int channels = 0;
  stbi_uc* rgba = stbi_load_from_memory(bytes.data(), static_cast<int>(bytes.size()), &width,
                                        &height, &channels, 4);
  if (rgba == nullptr) {
    *error = std::string("not a PNG or JPEG it can read (") + stbi_failure_reason() + ")";
    return false;
  }
  picture->width = static_cast<size_t>(width);
  picture->height = static_cast<size_t>(height);
  picture->bgra.assign(rgba, rgba + picture->width * picture->height * 4);
  stbi_image_free(rgba);
  for (size_t i = 0; i < picture->bgra.size(); i += 4) {
    std::swap(picture->bgra[i], picture->bgra[i + 2]);
  }
  return true;
}

std::vector<uint8_t> FitCameraPicture(const CameraPicture& picture, size_t width,
                                      size_t height) {
  std::vector<uint8_t> out(width * height * 4);
  if (picture.width == 0 || picture.height == 0) return out;
  // The larger of the two scales covers the frame; the source window is the
  // frame's size at that scale, centred.
  const double scale = std::max(static_cast<double>(width) / picture.width,
                                static_cast<double>(height) / picture.height);
  const double window_width = width / scale;
  const double window_height = height / scale;
  const double left = (picture.width - window_width) / 2;
  const double top = (picture.height - window_height) / 2;
  for (size_t y = 0; y < height; ++y) {
    const size_t source_y = std::min(
        static_cast<size_t>(top + (y + 0.5) * window_height / height), picture.height - 1);
    for (size_t x = 0; x < width; ++x) {
      const size_t source_x = std::min(
          static_cast<size_t>(left + (x + 0.5) * window_width / width), picture.width - 1);
      const uint8_t* from = picture.bgra.data() + (source_y * picture.width + source_x) * 4;
      uint8_t* to = out.data() + (y * width + x) * 4;
      to[0] = from[0];
      to[1] = from[1];
      to[2] = from[2];
      to[3] = 255;
    }
  }
  return out;
}

}  // namespace raccoon
