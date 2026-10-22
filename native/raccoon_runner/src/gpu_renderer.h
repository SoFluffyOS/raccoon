#pragma once
// What a GPU renderer offers beyond rasterizing: a ring of exported buffers
// the engine draws into, so a client that imports them gets each frame
// without a copy. GlRenderer exports DRM dmabufs on Linux, MetalRenderer
// IOSurfaces on macOS; EngineHost drives whichever this host builds.
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace raccoon {

// A set of exported GPU buffers, as a client needs to describe or import
// them. On Linux each buffer is a dmabuf: fourcc, modifier, stride, offset
// and a descriptor, which stays the renderer's; do not close them. On macOS
// each is an IOSurface named by its ID, with no descriptor.
struct GpuBufferSet {
  uint32_t generation = 0;
  size_t width = 0;
  size_t height = 0;
  uint32_t fourcc = 0;
  uint64_t modifier = 0;
  std::vector<uint32_t> strides;
  std::vector<uint32_t> offsets;
  std::vector<int> fds;
  std::vector<uint32_t> surface_ids;
};

class GpuRenderer {
 public:
  using FrameCallback = std::function<void(const void* pixels, size_t row_bytes,
                                           size_t height)>;
  // A frame drawn into pool buffer |index| of |generation|; |fence_fd| is
  // signalled when the draw is done, -1 when the draw was waited for
  // instead. The callback owns the descriptor.
  using GpuFrameCallback = std::function<void(uint32_t generation, int index,
                                              size_t width, size_t height,
                                              int fence_fd)>;

  virtual ~GpuRenderer() = default;

  virtual void Shutdown() = 0;

  // What rasterizes, for the log.
  virtual const std::string& description() const = 0;

  // Draw into a ring of |count| exported buffers from the next frame on,
  // while there is a free one. False, with why, when this renderer cannot
  // export.
  virtual bool EnablePool(size_t count, std::string* error) = 0;
  virtual void DisablePool() = 0;
  virtual void SetGpuFrameCallback(GpuFrameCallback callback) = 0;
  // The current set, false when the pool is off or not yet built.
  virtual bool pool_set(GpuBufferSet* out) const = 0;
  // Whether the next frame has a pool buffer to go into: true as well when
  // there is no pool, or none built yet.
  virtual bool HasFreeBuffer() const = 0;
  // The client is done with the buffer; a stale generation is ignored.
  // |fence_fd|, when not -1, is signalled once the client's last use of the
  // buffer is done; the renderer owns it from here.
  virtual void Release(uint32_t generation, int index, int fence_fd) = 0;
  // Every buffer is the renderer's again, fences dropped: for a client
  // that went away holding some.
  virtual void ReleaseAll() = 0;
};

}  // namespace raccoon
