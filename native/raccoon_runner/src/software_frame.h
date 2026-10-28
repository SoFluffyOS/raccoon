#pragma once

#include <chrono>
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
  SoftwareFrame() = default;
  // Closes a GPU frame's fence nobody took (a view whose client left).
  ~SoftwareFrame();
  SoftwareFrame(const SoftwareFrame&) = delete;
  SoftwareFrame& operator=(const SoftwareFrame&) = delete;

  struct Copy {
    // A string, so the frame message can take it without another copy.
    std::string pixels;
    size_t width = 0;
    size_t height = 0;
    size_t row_bytes = 0;
    size_t sequence = 0;
    // Its byte order: BGRA, else RGBA.
    bool bgra = kSoftwareFrameIsBgra;
  };

  // A frame that was presented into a shared buffer and not yet sent.
  struct Shared {
    int index = -1;
    size_t width = 0;
    size_t height = 0;
    size_t row_bytes = 0;
    size_t sequence = 0;
    bool bgra = kSoftwareFrameIsBgra;
  };

  // A frame the engine drew into a GPU buffer, not yet sent.
  struct Gpu {
    uint32_t generation = 0;
    int index = -1;
    size_t width = 0;
    size_t height = 0;
    size_t sequence = 0;
    // Signalled when the draw is done; -1 when it was waited for. Whoever
    // takes the frame owns it.
    int fence_fd = -1;
  };
  // A GPU buffer frame was drawn; from the raster thread. A pending one not
  // yet sent is superseded and its buffer released through the callback.
  void PresentGpu(uint32_t generation, int index, size_t width, size_t height,
                  int fence_fd);
  bool TakeGpu(Gpu* out);
  // Whether buffer |index| of |generation| is the GPU frame waiting to be
  // sent: the client can't have it yet.
  bool HoldsGpu(uint32_t generation, int index) const;
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

  // Copies |allocation| (row_bytes * height bytes, 4 bytes per pixel, BGRA
  // when |bgra|, else RGBA): the software renderer's order, unless a
  // renderer read it back in another.
  void Present(const void* allocation, size_t row_bytes, size_t height,
               bool bgra = kSoftwareFrameIsBgra);

  // Copies the latest frame into |out| when its sequence is newer than
  // |after_sequence|. Returns false otherwise, and while a frame that fits
  // the shared buffers waits for one to come back (PromoteInline).
  bool CopyLatest(Copy* out, size_t after_sequence);

  // A frame that found every shared buffer with the client waits for one,
  // for up to kInlineHold: a client that has not read the frames before it
  // reads an inline one no sooner, and twelve megabytes through the socket
  // would only slow it further. Moves it into a buffer given back since;
  // true when it did, and TakeShared then has it.
  bool PromoteInline();

  // Milliseconds until a waiting frame goes inline after all; -1 when none
  // waits.
  int MillisUntilInline() const;

  size_t FrameCount() const;

  // Writes the latest frame as a binary PPM. |bgra| says how the engine laid
  // out the pixel bytes. Returns false when there is no frame or the file
  // cannot be written.
  // Writes the latest inline frame, in its own byte order unless |rgba|.
  bool WritePpm(const std::string& path, bool rgba) const;

  size_t width() const { return width_; }
  size_t height() const { return height_; }

 private:
  mutable std::mutex mutex_;
  std::function<void()> presented_;
  std::vector<uint8_t> pixels_;
  bool pixels_bgra_ = kSoftwareFrameIsBgra;
  size_t width_ = 0;
  size_t height_ = 0;
  size_t row_bytes_ = 0;
  size_t frame_count_ = 0;
  // The frame whose pixels are in pixels_, 0 when none.
  size_t inline_sequence_ = 0;
  // That frame fits the shared buffers and waits for one, since inline_at_.
  bool inline_waits_ = false;
  std::chrono::steady_clock::time_point inline_at_;
  SharedBufferPool* pool_ = nullptr;
  Shared pending_shared_;
  Gpu pending_gpu_;
  std::function<void(uint32_t, int)> release_gpu_;
};

}  // namespace raccoon
