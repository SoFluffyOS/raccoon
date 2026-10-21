#pragma once
// Rasterizes the app on the GPU, through EGL without a window: the
// surfaceless platform, else the first device with a render node. The engine
// draws into a framebuffer here; each presented frame is read back as BGRA
// rows, top row first, and handed to the frame path, so clients see no
// difference from the software renderer. Reading 2400x1600 back takes well
// under a millisecond; what moves off the CPU is the rasterization.
#include <EGL/egl.h>
#include <GLES2/gl2.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace raccoon {

class GlRenderer {
 public:
  using FrameCallback = std::function<void(const void* pixels, size_t row_bytes,
                                           size_t height)>;

  bool Init(std::string* error);
  void Shutdown();

  // The engine's callbacks, on its raster thread.
  bool MakeCurrent();
  bool ClearCurrent();
  bool MakeResourceCurrent();
  // The framebuffer for a frame of this size, made or resized as needed;
  // 0 when it cannot be.
  uint32_t Fbo(size_t width, size_t height);
  // Reads the drawn frame back and hands it on. Context current.
  bool Present(const FrameCallback& callback);
  void* ProcAddress(const char* name) const;

  // What rasterizes: the GL_RENDERER string.
  const std::string& description() const { return description_; }

 private:
  bool EnsureSize(size_t width, size_t height);

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
};

}  // namespace raccoon
