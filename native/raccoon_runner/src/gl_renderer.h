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
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "flutter_embedder.h"
#include "gpu_renderer.h"

namespace raccoon {

class GlRenderer : public GpuRenderer {
 public:
  bool Init(std::string* error);
  // A target beside |of|, for another view (#182): drawn in |of|'s context,
  // with a framebuffer, ring and readback of its own. |of| outlives it.
  void InitSibling(const GlRenderer& of);
  // A sibling's goes with the context current, made so if it is not.
  void Shutdown() override;

  // The engine's callbacks, on its raster thread.
  bool MakeCurrent();
  // Makes the context current on this thread unless it is: the compositor's
  // callbacks may come without the engine having made it so.
  bool EnsureCurrent();
  bool ClearCurrent();
  bool MakeResourceCurrent();
  // The framebuffer for a frame of this size, made or resized as needed;
  // 0 when it cannot be. With a pool, a free pool buffer when there is one.
  uint32_t Fbo(size_t width, size_t height);
  // A frame went by: what was forgotten three frames ago is deleted. Fbo
  // counts its own; in views mode, where the root renderer makes no Fbo,
  // the host counts one per frame for it (#229).
  void CountFrame();
  // Hands the drawn frame on: to |gpu| when it is in a pool buffer, else read
  // back through |callback|. Context current.
  bool Present(const FrameCallback& callback);
  void* ProcAddress(const char* name) const;

  // What rasterizes: the GL_RENDERER string.
  const std::string& description() const override { return description_; }
  // Whether this display exports textures as dmabufs.
  bool can_export() const { return can_export_; }
  // Whether frames leave with a native fence rather than a glFinish.
  bool has_fences() const { return has_fences_; }

  // The pool is a ring of dmabufs; false, with why, when the display cannot
  // export.
  // External texture |texture_id| for the engine, on its raster thread with the
  // context current: |bgra|, rows of |width| * 4 bytes, in a texture kept
  // for that id and filled again when |number| changes. The camera's preview
  // comes this way.
  bool PixelTexture(int64_t texture_id, size_t width, size_t height, uint64_t number,
                    const uint8_t* bgra, FlutterOpenGLTexture* out);
  // Drops texture |texture_id|, from any thread; its name is deleted a few
  // frames later, the context current.
  void ForgetPixelTexture(int64_t texture_id);

  bool EnablePool(size_t count, std::string* error) override;
  void DisablePool() override;
  void SetGpuFrameCallback(GpuFrameCallback callback) override {
    gpu_frame_ = std::move(callback);
  }
  bool pool_set(GpuBufferSet* out) const override;
  bool HasFreeBuffer() const override;
  bool TakeMissedFrame() override;
  void Release(uint32_t generation, int index, int fence_fd) override;
  void ReleaseAll() override;

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
  // A sibling's context is its renderer's: it never makes or ends one.
  bool sibling_ = false;
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

  struct Pixels {
    GLuint name = 0;
    size_t width = 0;
    size_t height = 0;
    uint64_t number = 0;
  };
  std::mutex pixels_mutex_;
  std::unordered_map<int64_t, Pixels> pixels_;
  // Names to delete with the context current, and ids let go, which a
  // raster call that comes late does not make again (#114).
  std::vector<std::pair<GLuint, uint64_t>> forgotten_;
  std::unordered_set<int64_t> forgotten_ids_;
  // Frames asked for so far: a name let go is deleted a few frames later,
  // once no queued frame can still sample it.
  uint64_t frames_ = 0;
  void DeleteForgotten();
  std::vector<uint8_t> rgba_;

  mutable std::mutex mutex_;
  bool pool_wanted_ = false;
  size_t pool_count_ = 0;
  std::vector<Buffer> pool_;
  // One framebuffer for the whole pool, its colour attachment swapped per
  // frame: the engine keeps rendering only while the id it is given stays
  // the same.
  GLuint pool_fbo_ = 0;
  // The size a pool could not be built at: frames of that size go by
  // readback, and a pool is tried again at the next size (raccoon#241).
  size_t failed_width_ = 0;
  size_t failed_height_ = 0;
  size_t pool_width_ = 0;
  size_t pool_height_ = 0;
  uint32_t generation_ = 0;
  uint32_t fourcc_ = 0;
  uint64_t modifier_ = 0;
  // The pool buffer being drawn, -1 for the readback framebuffer.
  int current_ = -1;
  // A frame went by readback with every pool buffer taken; mutex_.
  bool missed_ = false;
  GpuFrameCallback gpu_frame_;
};

}  // namespace raccoon
