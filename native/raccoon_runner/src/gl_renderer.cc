#include "gl_renderer.h"

#include <poll.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>

#include <algorithm>
#include <cstring>

namespace raccoon {
namespace {

const bool kTrace = std::getenv("RACCOON_TRACE") != nullptr;

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

bool Has(const char* extensions, const char* name) {
  return extensions != nullptr && std::strstr(extensions, name) != nullptr;
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
  const char* gl_extensions =
      reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
  reads_bgra_ = Has(gl_extensions, "GL_EXT_read_format_bgra");
  const char* egl_extensions = eglQueryString(display_, EGL_EXTENSIONS);
  create_image_ = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
      eglGetProcAddress("eglCreateImageKHR"));
  destroy_image_ = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
      eglGetProcAddress("eglDestroyImageKHR"));
  export_query_ = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC>(
      eglGetProcAddress("eglExportDMABUFImageQueryMESA"));
  export_image_ = reinterpret_cast<PFNEGLEXPORTDMABUFIMAGEMESAPROC>(
      eglGetProcAddress("eglExportDMABUFImageMESA"));
  can_export_ = Has(egl_extensions, "EGL_MESA_image_dma_buf_export") &&
                Has(egl_extensions, "EGL_KHR_gl_texture_2D_image") &&
                create_image_ != nullptr && destroy_image_ != nullptr &&
                export_query_ != nullptr && export_image_ != nullptr;
  create_sync_ = reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(
      eglGetProcAddress("eglCreateSyncKHR"));
  destroy_sync_ = reinterpret_cast<PFNEGLDESTROYSYNCKHRPROC>(
      eglGetProcAddress("eglDestroySyncKHR"));
  client_wait_sync_ = reinterpret_cast<PFNEGLCLIENTWAITSYNCKHRPROC>(
      eglGetProcAddress("eglClientWaitSyncKHR"));
  wait_sync_ = reinterpret_cast<PFNEGLWAITSYNCKHRPROC>(
      eglGetProcAddress("eglWaitSyncKHR"));
  dup_fence_ = reinterpret_cast<PFNEGLDUPNATIVEFENCEFDANDROIDPROC>(
      eglGetProcAddress("eglDupNativeFenceFDANDROID"));
  has_fences_ = Has(egl_extensions, "EGL_KHR_fence_sync") &&
                Has(egl_extensions, "EGL_ANDROID_native_fence_sync") &&
                create_sync_ != nullptr && destroy_sync_ != nullptr &&
                client_wait_sync_ != nullptr && dup_fence_ != nullptr;
  has_wait_sync_ = Has(egl_extensions, "EGL_KHR_wait_sync") && wait_sync_ != nullptr;
  description_ = std::string(renderer == nullptr ? "?" : renderer) + ", " +
                 (version == nullptr ? "?" : version) + ", EGL " + how +
                 (can_export_ ? ", exports dmabufs" : "") +
                 (has_fences_ ? ", native fences" : "");
  ClearCurrent();
  return true;
}

void GlRenderer::InitSibling(const GlRenderer& of) {
  display_ = of.display_;
  sibling_ = true;
  config_ = of.config_;
  context_ = of.context_;
  reads_bgra_ = of.reads_bgra_;
  description_ = of.description_;
  can_export_ = of.can_export_;
  create_image_ = of.create_image_;
  destroy_image_ = of.destroy_image_;
  export_query_ = of.export_query_;
  export_image_ = of.export_image_;
  has_fences_ = of.has_fences_;
  has_wait_sync_ = of.has_wait_sync_;
  create_sync_ = of.create_sync_;
  destroy_sync_ = of.destroy_sync_;
  client_wait_sync_ = of.client_wait_sync_;
  wait_sync_ = of.wait_sync_;
  dup_fence_ = of.dup_fence_;
}

void GlRenderer::Shutdown() {
  if (display_ == EGL_NO_DISPLAY) return;
  if (sibling_) {
    // On the raster thread the context is current already; elsewhere the
    // engine has stopped, and nothing else holds it.
    const bool current = eglGetCurrentContext() == context_;
    if (current || MakeCurrent()) {
      std::lock_guard<std::mutex> lock(mutex_);
      DestroyPool();
      if (fbo_ != 0) glDeleteFramebuffers(1, &fbo_);
      if (texture_ != 0) glDeleteTextures(1, &texture_);
      fbo_ = texture_ = 0;
      if (!current) ClearCurrent();
    }
    display_ = EGL_NO_DISPLAY;
    context_ = EGL_NO_CONTEXT;
    return;
  }
  if (MakeCurrent()) {
    std::lock_guard<std::mutex> lock(mutex_);
    DestroyPool();
  } else {
    // No context for the GL names, but the descriptors need none.
    std::lock_guard<std::mutex> lock(mutex_);
    for (Buffer& buffer : pool_) {
      if (buffer.fence >= 0) close(buffer.fence);
      if (buffer.fd >= 0) close(buffer.fd);
      buffer.fence = buffer.fd = -1;
    }
  }
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

bool GlRenderer::EnsureCurrent() {
  return eglGetCurrentContext() == context_ || MakeCurrent();
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

namespace {

// The texture and framebuffer bound before, bound again on the way out: the
// engine's context is Skia's, whose cache of what is bound is not told, and
// without views mode nothing resets it around the framebuffer callback; a
// texture left bound here could be sampled for another (raccoon#241).
class BindingsKept {
 public:
  BindingsKept() {
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture_);
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &framebuffer_);
  }
  ~BindingsKept() {
    glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(texture_));
    glBindFramebuffer(GL_FRAMEBUFFER, static_cast<GLuint>(framebuffer_));
  }
  BindingsKept(const BindingsKept&) = delete;
  BindingsKept& operator=(const BindingsKept&) = delete;

 private:
  GLint texture_ = 0;
  GLint framebuffer_ = 0;
};

// Whether the GPU takes a texture of |width| by |height|: past its most,
// glTexImage2D fails and leaves the old storage, which the frame's size
// would then overrun on readback (raccoon#241).
bool FitsTexture(size_t width, size_t height) {
  GLint most = 0;
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, &most);
  return most <= 0 ||
         (width <= static_cast<size_t>(most) && height <= static_cast<size_t>(most));
}

}  // namespace

bool GlRenderer::EnsureSize(size_t width, size_t height) {
  if (fbo_ != 0 && width == width_ && height == height_) return true;
  if (!FitsTexture(width, height)) return false;
  BindingsKept kept;
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

bool GlRenderer::PixelTexture(int64_t texture_id, size_t width, size_t height, uint64_t number,
                              const uint8_t* bgra, FlutterOpenGLTexture* out) {
  if (width == 0 || height == 0) return false;
  std::lock_guard<std::mutex> lock(pixels_mutex_);
  DeleteForgotten();
  if (forgotten_ids_.count(texture_id) != 0) return false;
  Pixels& kept = pixels_[texture_id];
  const bool fresh = kept.name == 0;
  if (fresh) {
    glGenTextures(1, &kept.name);
    glBindTexture(GL_TEXTURE_2D, kept.name);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  } else {
    glBindTexture(GL_TEXTURE_2D, kept.name);
  }
  const bool resized = kept.width != width || kept.height != height;
  if (fresh || resized || kept.number != number) {
    // GLES 2 takes RGBA everywhere, BGRA only with an extension.
    rgba_.resize(width * height * 4);
    for (size_t i = 0; i < rgba_.size(); i += 4) {
      rgba_[i] = bgra[i + 2];
      rgba_[i + 1] = bgra[i + 1];
      rgba_[i + 2] = bgra[i];
      rgba_[i + 3] = bgra[i + 3];
    }
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    if (fresh || resized) {
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, static_cast<GLsizei>(width),
                   static_cast<GLsizei>(height), 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba_.data());
    } else {
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, static_cast<GLsizei>(width),
                      static_cast<GLsizei>(height), GL_RGBA, GL_UNSIGNED_BYTE, rgba_.data());
    }
    kept.width = width;
    kept.height = height;
    kept.number = number;
  }
  glBindTexture(GL_TEXTURE_2D, 0);
  out->target = GL_TEXTURE_2D;
  out->name = kept.name;
  out->format = GL_RGBA8_OES;
  out->user_data = nullptr;
  out->destruction_callback = nullptr;
  out->width = width;
  out->height = height;
  return true;
}

// pixels_mutex_ held, the context current. The engine lets a texture go
// with a task on this thread, and a frame queued before it may still draw
// the texture's cached image, which borrows the name: three frames on, none
// can (#114).
void GlRenderer::DeleteForgotten() {
  constexpr uint64_t kFramesKept = 3;
  std::vector<GLuint> names;
  auto kept = forgotten_.begin();
  for (const auto& [name, frame] : forgotten_) {
    if (frame + kFramesKept <= frames_) {
      names.push_back(name);
    } else {
      *kept++ = {name, frame};
    }
  }
  forgotten_.erase(kept, forgotten_.end());
  if (!names.empty()) glDeleteTextures(static_cast<GLsizei>(names.size()), names.data());
}

void GlRenderer::ForgetPixelTexture(int64_t texture_id) {
  std::lock_guard<std::mutex> lock(pixels_mutex_);
  forgotten_ids_.insert(texture_id);
  const auto found = pixels_.find(texture_id);
  if (found == pixels_.end()) return;
  forgotten_.emplace_back(found->second.name, frames_);
  pixels_.erase(found);
}

bool GlRenderer::EnablePool(size_t count, std::string* error) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!can_export_) {
    *error = "this EGL display does not export textures as dmabufs";
    return false;
  }
  pool_wanted_ = true;
  pool_count_ = count;
  // A new client tries every size afresh.
  failed_width_ = failed_height_ = 0;
  return true;
}

void GlRenderer::DisablePool() {
  std::lock_guard<std::mutex> lock(mutex_);
  pool_wanted_ = false;
}

bool GlRenderer::pool_set(GpuBufferSet* out) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (pool_.empty()) return false;
  out->generation = generation_;
  out->width = pool_width_;
  out->height = pool_height_;
  out->fourcc = fourcc_;
  out->modifier = modifier_;
  out->strides.clear();
  out->offsets.clear();
  out->fds.clear();
  for (const Buffer& buffer : pool_) {
    out->strides.push_back(buffer.stride);
    out->offsets.push_back(buffer.offset);
    out->fds.push_back(buffer.fd);
  }
  return true;
}

bool GlRenderer::TakeMissedFrame() {
  std::lock_guard<std::mutex> lock(mutex_);
  const bool missed = missed_;
  missed_ = false;
  return missed;
}

bool GlRenderer::HasFreeBuffer() const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!pool_wanted_ || pool_.empty()) return true;
  for (const Buffer& buffer : pool_) {
    if (!buffer.busy) return true;
  }
  return false;
}

void GlRenderer::Release(uint32_t generation, int index, int fence_fd) {
  std::lock_guard<std::mutex> lock(mutex_);
  // The buffer being drawn was never handed out: a release naming it is
  // late or a duplicate, and freeing it would let the next frame draw into
  // what the client shows (#124).
  if (generation != generation_ || index < 0 ||
      static_cast<size_t>(index) >= pool_.size() || index == current_ ||
      index == presenting_) {
    if (fence_fd >= 0) close(fence_fd);
    return;
  }
  Buffer& buffer = pool_[index];
  if (buffer.fence >= 0) close(buffer.fence);
  buffer.fence = fence_fd;
  buffer.busy = false;
  if (kTrace) {
    std::fprintf(stderr, "🦝 gl release pool %d%s\n", index,
                 fence_fd >= 0 ? " (fenced)" : "");
  }
}

void GlRenderer::ReleaseAll() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (size_t i = 0; i < pool_.size(); ++i) {
    Buffer& buffer = pool_[i];
    if (buffer.fence >= 0) close(buffer.fence);
    buffer.fence = -1;
    // The one being drawn stays taken until it is presented, and one being
    // presented until it is handed on.
    if (static_cast<int>(i) == current_ || static_cast<int>(i) == presenting_) continue;
    buffer.busy = false;
  }
  if (kTrace) std::fprintf(stderr, "🦝 gl release pool all\n");
}

int GlRenderer::ExportFence() {
  if (!has_fences_) return -1;
  const EGLSyncKHR sync =
      create_sync_(display_, EGL_SYNC_NATIVE_FENCE_ANDROID, nullptr);
  if (sync == EGL_NO_SYNC_KHR) return -1;
  // The fence is only submitted with the commands before it.
  glFlush();
  const int fd = dup_fence_(display_, sync);
  destroy_sync_(display_, sync);
  return fd;
}

void GlRenderer::WaitFence(int fence_fd) {
  // Without native fences here, the client's is still a sync file, which
  // polls readable once signalled: waited on so, bounded as below, rather
  // than dropped while the client may still be reading the buffer
  // (raccoon#241).
  const auto poll_fence = [fence_fd] {
    pollfd ready{fence_fd, POLLIN, 0};
    poll(&ready, 1, 100);
    close(fence_fd);
  };
  if (!has_fences_) {
    poll_fence();
    return;
  }
  const EGLint attributes[] = {EGL_SYNC_NATIVE_FENCE_FD_ANDROID, fence_fd, EGL_NONE};
  // The sync owns the descriptor from here.
  const EGLSyncKHR sync =
      create_sync_(display_, EGL_SYNC_NATIVE_FENCE_ANDROID, attributes);
  if (sync == EGL_NO_SYNC_KHR) {
    poll_fence();
    return;
  }
  if (has_wait_sync_) {
    wait_sync_(display_, sync, 0);
  } else {
    // On the CPU, so bounded: a host whose GPU hangs reading the buffer
    // must not hold the app's raster thread for good (raccoon#157).
    constexpr EGLTimeKHR kFenceWaitNs = 100 * 1000 * 1000;
    client_wait_sync_(display_, sync, 0, kFenceWaitNs);
  }
  destroy_sync_(display_, sync);
}

void GlRenderer::DestroyPool() {
  for (Buffer& buffer : pool_) {
    if (buffer.fence >= 0) close(buffer.fence);
    if (buffer.fd >= 0) close(buffer.fd);
    if (buffer.image != EGL_NO_IMAGE_KHR) destroy_image_(display_, buffer.image);
    if (buffer.texture != 0) glDeleteTextures(1, &buffer.texture);
  }
  if (pool_fbo_ != 0) {
    glDeleteFramebuffers(1, &pool_fbo_);
    pool_fbo_ = 0;
  }
  pool_.clear();
  pool_width_ = pool_height_ = 0;
}

bool GlRenderer::BuildPool(size_t width, size_t height) {
  DestroyPool();
  if (!FitsTexture(width, height)) return false;
  BindingsKept kept;
  glGenFramebuffers(1, &pool_fbo_);
  std::vector<Buffer> buffers(pool_count_);
  for (Buffer& buffer : buffers) {
    glGenTextures(1, &buffer.texture);
    glBindTexture(GL_TEXTURE_2D, buffer.texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, static_cast<GLsizei>(width),
                 static_cast<GLsizei>(height), 0, GL_RGBA, GL_UNSIGNED_BYTE,
                 nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glBindFramebuffer(GL_FRAMEBUFFER, pool_fbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           buffer.texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
      break;
    }
    buffer.image = create_image_(
        display_, context_, EGL_GL_TEXTURE_2D_KHR,
        reinterpret_cast<EGLClientBuffer>(static_cast<uintptr_t>(buffer.texture)),
        nullptr);
    if (buffer.image == EGL_NO_IMAGE_KHR) break;
    int fourcc = 0;
    int planes = 0;
    EGLuint64KHR modifier = 0;
    if (!export_query_(display_, buffer.image, &fourcc, &planes, &modifier) ||
        planes != 1) {
      break;
    }
    int fds[4] = {-1, -1, -1, -1};
    EGLint strides[4] = {0, 0, 0, 0};
    EGLint offsets[4] = {0, 0, 0, 0};
    if (!export_image_(display_, buffer.image, fds, strides, offsets)) break;
    buffer.fd = fds[0];
    buffer.stride = static_cast<uint32_t>(strides[0]);
    buffer.offset = static_cast<uint32_t>(offsets[0]);
    fourcc_ = static_cast<uint32_t>(fourcc);
    modifier_ = modifier;
  }
  const bool complete =
      !buffers.empty() && buffers.back().fd >= 0 &&
      static_cast<size_t>(std::count_if(buffers.begin(), buffers.end(),
                                        [](const Buffer& b) { return b.fd >= 0; })) ==
          buffers.size();
  pool_ = std::move(buffers);
  if (!complete) {
    DestroyPool();
    return false;
  }
  pool_width_ = width;
  pool_height_ = height;
  ++generation_;
  if (kTrace) {
    std::fprintf(stderr, "🦝 gl pool %zu x %zux%zu generation %u\n",
                 pool_.size(), width, height, generation_);
  }
  return true;
}

void GlRenderer::CountFrame() {
  std::lock_guard<std::mutex> lock(pixels_mutex_);
  ++frames_;
  DeleteForgotten();
}

uint32_t GlRenderer::Fbo(size_t width, size_t height) {
  if (width == 0 || height == 0) return 0;
  CountFrame();
  int fence = -1;
  uint32_t fbo = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // A buffer the engine took and never presented (a frame it dropped) was
    // never handed out.
    if (current_ >= 0 && static_cast<size_t>(current_) < pool_.size()) {
      pool_[current_].busy = false;
    }
    current_ = -1;
    if (!pool_wanted_ && !pool_.empty()) DestroyPool();
    if (pool_wanted_ && can_export_) {
      const bool stale = pool_.empty() || pool_width_ != width || pool_height_ != height;
      // One that can't be built at a size is tried again at the next:
      // turned off for good, a window back at a size that works stayed on
      // readback (raccoon#241). Back at the size that failed, a pool of
      // another size goes, as a failed build left none.
      if (stale && width == failed_width_ && height == failed_height_) {
        if (!pool_.empty()) DestroyPool();
      } else if (stale) {
        if (!BuildPool(width, height)) {
          failed_width_ = width;
          failed_height_ = height;
          std::fprintf(stderr,
                       "🦝 no GPU buffers at %zux%zu: the pool could not be "
                       "built; frames by readback\n",
                       width, height);
        }
      }
      for (size_t i = 0; i < pool_.size(); ++i) {
        if (pool_[i].busy) continue;
        pool_[i].busy = true;
        current_ = static_cast<int>(i);
        fence = pool_[i].fence;
        pool_[i].fence = -1;
        glBindFramebuffer(GL_FRAMEBUFFER, pool_fbo_);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, pool_[i].texture, 0);
        if (kTrace) std::fprintf(stderr, "🦝 gl fbo -> pool %zu\n", i);
        fbo = pool_fbo_;
        break;
      }
      // Every buffer is with the client: this frame goes by readback.
    }
    if (fbo == 0) {
      if (kTrace && pool_wanted_) std::fprintf(stderr, "🦝 gl fbo -> readback\n");
      fbo = EnsureSize(width, height) ? fbo_ : 0;
    }
  }
  // The client may still be reading the buffer: draw after that. Outside
  // the lock, so a wait on the CPU does not hold up releases.
  if (fence >= 0) WaitFence(fence);
  return fbo;
}

bool GlRenderer::Present(const FrameCallback& callback) {
  int index = -1;
  uint32_t generation = 0;
  size_t width = 0;
  size_t height = 0;
  bool pooled = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    index = current_;
    generation = generation_;
    width = pool_width_;
    height = pool_height_;
    pooled = pool_wanted_;
    current_ = -1;
    presenting_ = pooled ? index : -1;
    // A frame going by readback while a client takes the ring: it never
    // sees it. Marked here, where it goes, not where Skia took the
    // framebuffer for it a frame before.
    if (index < 0 && pool_wanted_ && !pool_.empty()) missed_ = true;
  }
  if (index >= 0 && pooled) {
    // The client reads the buffer from its own context: it gets a fence for
    // the draw, or, without fences, the draw is waited for here.
    int fence = ExportFence();
    if (fence < 0) glFinish();
    if (kTrace) {
      std::fprintf(stderr, "🦝 gl present pool %d%s\n", index,
                   fence >= 0 ? " (fenced)" : "");
    }
    if (gpu_frame_) {
      gpu_frame_(generation, index, width, height, fence);
    } else if (fence >= 0) {
      close(fence);
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      presenting_ = -1;
    }
    return true;
  }
  // The pool went off while this frame was drawn into one of its buffers
  // (Skia's GL surface takes the next frame's buffer at present): nobody
  // takes buffers now, so its pixels go as a readback frame.
  GLuint source = fbo_;
  if (index >= 0) {
    if (!EnsureSize(width, height)) return false;
    source = pool_fbo_;
  }
  if (fbo_ == 0) return false;
  glBindFramebuffer(GL_FRAMEBUFFER, source);
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
