#pragma once

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace raccoon {

// Keeps the latest frame the software renderer presented. The present
// callback runs on the engine's raster thread; readers wait on a condition.
class SoftwareFrame {
 public:
  // Copies |allocation| (row_bytes * height bytes, 4 bytes per pixel).
  void Present(const void* allocation, size_t row_bytes, size_t height);

  // Blocks until at least |count| frames were presented or |timeout| passed.
  // Returns the number of frames presented so far.
  size_t WaitForFrames(size_t count, std::chrono::milliseconds timeout);

  // Writes the latest frame as a binary PPM. |bgra| says how the engine laid
  // out the pixel bytes. Returns false when there is no frame or the file
  // cannot be written.
  bool WritePpm(const std::string& path, bool bgra) const;

  size_t FrameCount() const;

  size_t width() const { return width_; }
  size_t height() const { return height_; }

 private:
  mutable std::mutex mutex_;
  std::condition_variable presented_;
  std::vector<uint8_t> pixels_;
  size_t width_ = 0;
  size_t height_ = 0;
  size_t row_bytes_ = 0;
  size_t frame_count_ = 0;
};

}  // namespace raccoon
