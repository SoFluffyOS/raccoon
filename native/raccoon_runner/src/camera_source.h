#pragma once

// What the camera shows in place of its test pattern: a PNG or JPEG,
// decoded once, or a video, played in a loop; each frame is then fitted to
// each camera's size.

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace raccoon {

struct CameraPicture {
  size_t width = 0;
  size_t height = 0;
  // Rows of width * 4 bytes, blue first.
  std::vector<uint8_t> bgra;
};

class CameraSource {
 public:
  virtual ~CameraSource() = default;

  // The frame showing |time_micros| after the source was opened, and its
  // number, which changes when the frame does; null when there is none.
  virtual const CameraPicture* FrameAt(uint64_t time_micros, uint64_t* number) = 0;
};

// The source at |path|, UTF-8: a picture by its .png, .jpg or .jpeg
// extension, a video otherwise. Null with |error| set when it does not open.
std::unique_ptr<CameraSource> OpenCameraSource(const std::string& path, std::string* error);

// Decodes the PNG or JPEG at |path|, UTF-8; false with |error| set when
// there is none or it does not decode.
bool LoadCameraPicture(const std::string& path, CameraPicture* picture, std::string* error);

// A video played in a loop, decoded by the host's media framework; null
// with |error| set where there is none (camera_video_win.cc on Windows).
std::unique_ptr<CameraSource> OpenCameraVideo(const std::string& path, std::string* error);

// |picture| filling |width| x |height|: scaled to cover it, centred, the
// overflow cropped, as a camera's sensor crops to its preset.
std::vector<uint8_t> FitCameraPicture(const CameraPicture& picture, size_t width,
                                      size_t height);

}  // namespace raccoon
