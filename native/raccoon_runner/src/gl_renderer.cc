#include "gl_renderer.h"

#include <EGL/eglext.h>
#include <GLES2/gl2ext.h>

#include <cstring>

namespace raccoon {
namespace {

EGLDisplay OpenDisplay(std::string* how) {
  const auto get_platform_display =
      reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
          eglGetProcAddress("eglGetPlatformDisplayEXT"));
  if (get_platform_display == nullptr) return EGL_NO_DISPLAY;
  const char* extensions = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
  if (extensions != nullptr &&
      std::strstr(extensions, "EGL_MESA_platform_surfaceless") != nullptr) {
    const EGLDisplay display = get_platform_display(
        EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr);
    if (display != EGL_NO_DISPLAY) {
      *how = "surfaceless";
      return display;
    }
  }
  const auto query_devices = reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(
      eglGetProcAddress("eglQueryDevicesEXT"));
  const auto query_device_string =
      reinterpret_cast<PFNEGLQUERYDEVICESTRINGEXTPROC>(
          eglGetProcAddress("eglQueryDeviceStringEXT"));
  if (query_devices == nullptr) return EGL_NO_DISPLAY;
  EGLDeviceEXT devices[8];
  EGLint count = 0;
  if (!query_devices(8, devices, &count) || count == 0) return EGL_NO_DISPLAY;
  // A device with a render node is a GPU; the rest is software GL.
  for (EGLint i = 0; i < count; ++i) {
    const char* node =
        query_device_string == nullptr
            ? nullptr
            : query_device_string(devices[i], EGL_DRM_RENDER_NODE_FILE_EXT);
    if (node == nullptr) continue;
    const EGLDisplay display =
        get_platform_display(EGL_PLATFORM_DEVICE_EXT, devices[i], nullptr);
    if (display != EGL_NO_DISPLAY) {
      *how = node;
      return display;
    }
  }
  *how = "device";
  return get_platform_display(EGL_PLATFORM_DEVICE_EXT, devices[0], nullptr);
}

}  // namespace

bool GlRenderer::Init(std::string* error) {
  std::string how;
  display_ = OpenDisplay(&how);
  if (display_ == EGL_NO_DISPLAY) {
    *error = "no EGL display without a window";
    return false;
  }
  EGLint major = 0;
  EGLint minor = 0;
  if (!eglInitialize(display_, &major, &minor)) {
    *error = "eglInitialize failed";
    return false;
  }
  eglBindAPI(EGL_OPENGL_ES_API);
  // Without a surface type named, EGL assumes a window; configs without a
  // window offer pbuffers, or nothing at all on the surfaceless platform.
  const EGLint pbuffer[] = {EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
                            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                            EGL_RED_SIZE,        8,
                            EGL_GREEN_SIZE,      8,
                            EGL_BLUE_SIZE,       8,
                            EGL_ALPHA_SIZE,      8,
                            EGL_NONE};
  const EGLint any_surface[] = {EGL_SURFACE_TYPE,    0,
                                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                EGL_NONE};
  EGLint configs = 0;
  if ((!eglChooseConfig(display_, pbuffer, &config_, 1, &configs) ||
       configs == 0) &&
      (!eglChooseConfig(display_, any_surface, &config_, 1, &configs) ||
       configs == 0)) {
    *error = "no EGL config for OpenGL ES 2";
    return false;
  }
  const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  context_ =
      eglCreateContext(display_, config_, EGL_NO_CONTEXT, context_attributes);
  if (context_ == EGL_NO_CONTEXT) {
    *error = "eglCreateContext failed";
    return false;
  }
  resource_context_ =
      eglCreateContext(display_, config_, context_, context_attributes);
  if (!MakeCurrent()) {
    *error = "eglMakeCurrent failed";
    return false;
  }
  const char* renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
  const char* version = reinterpret_cast<const char*>(glGetString(GL_VERSION));
  const char* extensions =
      reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
  reads_bgra_ = extensions != nullptr &&
                std::strstr(extensions, "GL_EXT_read_format_bgra") != nullptr;
  description_ = std::string(renderer == nullptr ? "?" : renderer) + ", " +
                 (version == nullptr ? "?" : version) + ", EGL " + how;
  ClearCurrent();
  return true;
}

void GlRenderer::Shutdown() {
  if (display_ == EGL_NO_DISPLAY) return;
  eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  if (resource_context_ != EGL_NO_CONTEXT) {
    eglDestroyContext(display_, resource_context_);
  }
  if (context_ != EGL_NO_CONTEXT) eglDestroyContext(display_, context_);
  eglTerminate(display_);
  display_ = EGL_NO_DISPLAY;
  context_ = resource_context_ = EGL_NO_CONTEXT;
}

bool GlRenderer::MakeCurrent() {
  return eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, context_) ==
         EGL_TRUE;
}

bool GlRenderer::ClearCurrent() {
  return eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE,
                        EGL_NO_CONTEXT) == EGL_TRUE;
}

bool GlRenderer::MakeResourceCurrent() {
  if (resource_context_ == EGL_NO_CONTEXT) return false;
  return eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE,
                        resource_context_) == EGL_TRUE;
}

void* GlRenderer::ProcAddress(const char* name) const {
  return reinterpret_cast<void*>(eglGetProcAddress(name));
}

bool GlRenderer::EnsureSize(size_t width, size_t height) {
  if (fbo_ != 0 && width == width_ && height == height_) return true;
  if (fbo_ == 0) {
    glGenTextures(1, &texture_);
    glGenFramebuffers(1, &fbo_);
  }
  glBindTexture(GL_TEXTURE_2D, texture_);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, static_cast<GLsizei>(width),
               static_cast<GLsizei>(height), 0, GL_RGBA, GL_UNSIGNED_BYTE,
               nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         texture_, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    return false;
  }
  width_ = width;
  height_ = height;
  readback_.resize(width * height * 4);
  frame_.resize(width * height * 4);
  return true;
}

uint32_t GlRenderer::Fbo(size_t width, size_t height) {
  if (width == 0 || height == 0) return 0;
  return EnsureSize(width, height) ? fbo_ : 0;
}

bool GlRenderer::Present(const FrameCallback& callback) {
  if (fbo_ == 0) return false;
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glReadPixels(0, 0, static_cast<GLsizei>(width_), static_cast<GLsizei>(height_),
               reads_bgra_ ? GL_BGRA_EXT : GL_RGBA, GL_UNSIGNED_BYTE,
               readback_.data());
  // GL's rows come bottom first; the frame path wants the top row first.
  const size_t row_bytes = width_ * 4;
  for (size_t row = 0; row < height_; ++row) {
    const uint8_t* source = readback_.data() + (height_ - 1 - row) * row_bytes;
    uint8_t* target = frame_.data() + row * row_bytes;
    if (reads_bgra_) {
      std::memcpy(target, source, row_bytes);
      continue;
    }
    for (size_t x = 0; x < width_; ++x) {
      target[x * 4 + 0] = source[x * 4 + 2];
      target[x * 4 + 1] = source[x * 4 + 1];
      target[x * 4 + 2] = source[x * 4 + 0];
      target[x * 4 + 3] = source[x * 4 + 3];
    }
  }
  callback(frame_.data(), row_bytes, height_);
  return true;
}

}  // namespace raccoon
