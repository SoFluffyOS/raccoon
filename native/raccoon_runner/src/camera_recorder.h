#pragma once

// The camera's video recordings: what it shows, encoded to an MP4 as it
// goes (camera_recorder_win.cc, Media Foundation's sink writer, on Windows;
// no other host records yet).

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace raccoon {

class CameraRecorder {
 public:
  virtual ~CameraRecorder() = default;

  // Adds a frame, rows of width * 4 bytes, blue first, shown |time_micros|
  // into the recording; times only grow.
  virtual bool Write(const uint8_t* bgra, uint64_t time_micros) = 0;

  // Closes the file; false with |error| set when it could not be finished.
  virtual bool Finish(std::string* error) = 0;
};

// Starts an H.264 MP4 at |path|, UTF-8, of |width| x |height| at |fps|; null
// with |error| set where it cannot.
std::unique_ptr<CameraRecorder> StartCameraRecorder(const std::string& path, size_t width,
                                                    size_t height, int fps, std::string* error);

}  // namespace raccoon
