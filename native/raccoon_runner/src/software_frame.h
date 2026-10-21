#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

namespace raccoon {

// Keeps the latest frame the software renderer presented. Present runs on the
// engine's raster thread; everything else on the owner's thread.
class SoftwareFrame {
 public:
  struct Copy {
    std::vector<uint8_t> pixels;
    size_t width = 0;
    size_t height = 0;
    size_t row_bytes = 0;
    size_t sequence = 0;
  };

  // Called after every Present, from the raster thread.
  void SetPresentedCallback(std::function<void()> callback) {
    presented_ = std::move(callback);
  }

  // Copies |allocation| (row_bytes * height bytes, 4 bytes per pixel).
  void Present(const void* allocation, size_t row_bytes, size_t height);

  // Copies the latest frame into |out| when its sequence is newer than
  // |after_sequence|. Returns false otherwise.
  bool CopyLatest(Copy* out, size_t after_sequence) const;

  size_t FrameCount() const;

  // Writes the latest frame as a binary PPM. |bgra| says how the engine laid
  // out the pixel bytes. Returns false when there is no frame or the file
  // cannot be written.
  bool WritePpm(const std::string& path, bool bgra) const;

  size_t width() const { return width_; }
  size_t height() const { return height_; }

 private:
  mutable std::mutex mutex_;
  std::function<void()> presented_;
  std::vector<uint8_t> pixels_;
  size_t width_ = 0;
  size_t height_ = 0;
  size_t row_bytes_ = 0;
  size_t frame_count_ = 0;
};

}  // namespace raccoon
