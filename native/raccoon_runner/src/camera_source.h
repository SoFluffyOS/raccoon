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

// A video played in a loop, from its first frame again after its last: the
// timing every host's decoder shares; the decoder reads the frames.
class LoopingVideo : public CameraSource {
 public:
  const CameraPicture* FrameAt(uint64_t time_micros, uint64_t* number) override;

 protected:
  // Reads the first two frames, once the decoder is open; false when there
  // is not one.
  bool Begin();
  // The next frame, rows of width * 4 bytes, blue first, and its time from
  // the start; false at the end or on an error.
  virtual bool ReadNext(CameraPicture* frame, int64_t* time_micros) = 0;
  // Back to the first frame, for the next pass.
  virtual void Restart() = 0;

  // The video's length; 0 when it does not say, and then its last frame
  // stays.
  int64_t duration_micros_ = 0;

 private:
  CameraPicture current_;
  int64_t current_time_ = 0;
  CameraPicture next_;
  int64_t next_time_ = 0;
  bool has_next_ = false;
  uint64_t frame_number_ = 1;
  uint64_t opened_at_ = 0;
  bool opened_at_set_ = false;
  int64_t last_position_ = 0;
};

// The source at |path|, UTF-8: a picture by its .png, .jpg or .jpeg
// extension, a video otherwise. Null with |error| set when it does not open.
std::unique_ptr<CameraSource> OpenCameraSource(const std::string& path, std::string* error);

// Decodes the PNG or JPEG at |path|, UTF-8; false with |error| set when
// there is none or it does not decode.
bool LoadCameraPicture(const std::string& path, CameraPicture* picture, std::string* error);

// A video played in a loop, decoded by the host's media framework; null
// with |error| set where there is none (camera_video_win.cc on Windows,
// camera_video_mac.mm on macOS).
std::unique_ptr<CameraSource> OpenCameraVideo(const std::string& path, std::string* error);

// |picture| filling |width| x |height|: scaled to cover it, centred, the
// overflow cropped, as a camera's sensor crops to its preset.
std::vector<uint8_t> FitCameraPicture(const CameraPicture& picture, size_t width,
                                      size_t height);

}  // namespace raccoon
