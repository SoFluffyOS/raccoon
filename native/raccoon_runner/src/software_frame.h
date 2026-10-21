#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include "shared_buffers.h"

namespace raccoon {

// The byte order the software renderer rasters in: Skia's native 32-bit
// colour type, which is BGRA on Linux and Windows and RGBA on Apple hosts.
#if defined(__APPLE__)
constexpr bool kSoftwareFrameIsBgra = false;
#else
constexpr bool kSoftwareFrameIsBgra = true;
#endif

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

  // A frame that was presented into a shared buffer and not yet sent.
  struct Shared {
    int index = -1;
    size_t width = 0;
    size_t height = 0;
    size_t row_bytes = 0;
    size_t sequence = 0;
  };

  // A frame the engine drew into a GPU buffer, not yet sent.
  struct Gpu {
    uint32_t generation = 0;
    int index = -1;
    size_t width = 0;
    size_t height = 0;
    size_t sequence = 0;
  };
  // A GPU buffer frame was drawn; from the raster thread. A pending one not
  // yet sent is superseded and its buffer released through the callback.
  void PresentGpu(uint32_t generation, int index, size_t width, size_t height);
  bool TakeGpu(Gpu* out);
  void SetGpuReleaseCallback(std::function<void(uint32_t, int)> callback) {
    release_gpu_ = std::move(callback);
  }

  // Frames are presented into |pool|'s buffers from now on; null returns to
  // inline copies. The pool must outlive the setting.
  void SetSharedPool(SharedBufferPool* pool);

  // Takes the pending shared frame, if any. Its buffer stays busy until the
  // client releases it.
  bool TakeShared(Shared* out);

  // Bytes the latest frame needs: row bytes times height, 0 before a frame.
  size_t LatestSizeBytes() const;

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
  // The frame whose pixels are in pixels_, 0 when none.
  size_t inline_sequence_ = 0;
  SharedBufferPool* pool_ = nullptr;
  Shared pending_shared_;
  Gpu pending_gpu_;
  std::function<void(uint32_t, int)> release_gpu_;
};

}  // namespace raccoon
