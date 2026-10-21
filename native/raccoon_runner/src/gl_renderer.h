#pragma once
// Rasterizes the app on the GPU, through EGL without a window: the
// surfaceless platform, else the first device with a render node. The engine
// draws into a framebuffer here.
//
// Two ways out. By default each presented frame is read back as BGRA rows,
// top row first, and handed to the frame path, so clients see no difference
// from the software renderer; reading 2400x1600 back takes well under a
// millisecond, what moves off the CPU is the rasterization. With a pool
// enabled, the engine draws straight into a ring of textures exported as
// DRM dmabufs, and a frame is just the index of the buffer it is in; a client
// that imports them gets the frame without a copy.
//
// Where EGL has native fences, a frame leaves with a fence in place of a
// glFinish, and a buffer comes back with one the client made after its last
// use of it, waited on before the engine draws there again.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

namespace raccoon {

// A set of exported GPU buffers, as a client needs to describe or import
// them. The descriptors stay the renderer's; do not close them.
struct GpuBufferSet {
  uint32_t generation = 0;
  size_t width = 0;
  size_t height = 0;
  uint32_t fourcc = 0;
  uint64_t modifier = 0;
  std::vector<uint32_t> strides;
  std::vector<uint32_t> offsets;
  std::vector<int> fds;
};

class GlRenderer {
 public:
  using FrameCallback = std::function<void(const void* pixels, size_t row_bytes,
                                           size_t height)>;
  // A frame drawn into pool buffer |index| of |generation|; |fence_fd| is
  // signalled when the draw is done, -1 when the draw was waited for
  // instead. The callback owns the descriptor.
  using GpuFrameCallback = std::function<void(uint32_t generation, int index,
                                              size_t width, size_t height,
                                              int fence_fd)>;

  bool Init(std::string* error);
  void Shutdown();

  // The engine's callbacks, on its raster thread.
  bool MakeCurrent();
  bool ClearCurrent();
  bool MakeResourceCurrent();
  // The framebuffer for a frame of this size, made or resized as needed;
  // 0 when it cannot be. With a pool, a free pool buffer when there is one.
  uint32_t Fbo(size_t width, size_t height);
  // Hands the drawn frame on: to |gpu| when it is in a pool buffer, else read
  // back through |callback|. Context current.
  bool Present(const FrameCallback& callback);
  void* ProcAddress(const char* name) const;

  // What rasterizes: the GL_RENDERER string.
  const std::string& description() const { return description_; }
  // Whether this display exports textures as dmabufs.
  bool can_export() const { return can_export_; }
  // Whether frames leave with a native fence rather than a glFinish.
  bool has_fences() const { return has_fences_; }

  // Draw into a ring of |count| exported buffers from the next frame on,
  // while there is a free one. False, with why, when the display cannot
  // export.
  bool EnablePool(size_t count, std::string* error);
  void DisablePool();
  void SetGpuFrameCallback(GpuFrameCallback callback) {
    gpu_frame_ = std::move(callback);
  }
  // The current set, false when the pool is off or not yet built.
  bool pool_set(GpuBufferSet* out) const;
  // The client is done with the buffer; a stale generation is ignored.
  // |fence_fd|, when not -1, is signalled once the client's last use of the
  // buffer is done; the renderer owns it from here.
  void Release(uint32_t generation, int index, int fence_fd = -1);
  // Every buffer is the renderer's again, fences dropped: for a client
  // that went away holding some.
  void ReleaseAll();

 private:
  struct Buffer {
    GLuint texture = 0;
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    int fd = -1;
    uint32_t stride = 0;
    uint32_t offset = 0;
    bool busy = false;
    // The client's fence for its last use, waited on before the next draw.
    int fence = -1;
  };

  bool EnsureSize(size_t width, size_t height);
  // A native fence for the drawing issued so far, -1 when there is none.
  // Context current.
  int ExportFence();
  // Makes the context wait for |fence_fd| (owned from here). Context current.
  void WaitFence(int fence_fd);
  // Context current, mutex held.
  bool BuildPool(size_t width, size_t height);
  void DestroyPool();

  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLConfig config_ = nullptr;
  EGLContext context_ = EGL_NO_CONTEXT;
  EGLContext resource_context_ = EGL_NO_CONTEXT;
  GLuint fbo_ = 0;
  GLuint texture_ = 0;
  size_t width_ = 0;
  size_t height_ = 0;
  bool reads_bgra_ = false;
  std::vector<uint8_t> readback_;
  std::vector<uint8_t> frame_;
  std::string description_;

  bool can_export_ = false;
  PFNEGLCREATEIMAGEKHRPROC create_image_ = nullptr;
  PFNEGLDESTROYIMAGEKHRPROC destroy_image_ = nullptr;
  PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC export_query_ = nullptr;
  PFNEGLEXPORTDMABUFIMAGEMESAPROC export_image_ = nullptr;
  bool has_fences_ = false;
  bool has_wait_sync_ = false;
  PFNEGLCREATESYNCKHRPROC create_sync_ = nullptr;
  PFNEGLDESTROYSYNCKHRPROC destroy_sync_ = nullptr;
  PFNEGLCLIENTWAITSYNCKHRPROC client_wait_sync_ = nullptr;
  PFNEGLWAITSYNCKHRPROC wait_sync_ = nullptr;
  PFNEGLDUPNATIVEFENCEFDANDROIDPROC dup_fence_ = nullptr;

  mutable std::mutex mutex_;
  bool pool_wanted_ = false;
  size_t pool_count_ = 0;
  std::vector<Buffer> pool_;
  // One framebuffer for the whole pool, its colour attachment swapped per
  // frame: the engine keeps rendering only while the id it is given stays
  // the same.
  GLuint pool_fbo_ = 0;
  size_t pool_width_ = 0;
  size_t pool_height_ = 0;
  uint32_t generation_ = 0;
  uint32_t fourcc_ = 0;
  uint64_t modifier_ = 0;
  // The pool buffer being drawn, -1 for the readback framebuffer.
  int current_ = -1;
  GpuFrameCallback gpu_frame_;
};

}  // namespace raccoon
