// The host side of Raccoon's GPU buffers on Linux. Dart asks for a texture,
// names the runner's GPU socket, then names each frame's buffer; this side
// takes the buffers' descriptors from that socket, imports them into
// Flutter's own GL context the first time it is asked to populate the
// texture, and from then on populates with the buffer of the latest frame.
//
// Channel raccoon_view/gpu: create() -> textureId; connect(textureId,
// socket) -> whether buffers go back from here; show(textureId, generation,
// index); dispose(textureId).
//
// Each frame comes with a fence where EGL has native fences: Flutter's
// context waits on it before sampling. A buffer goes back to the runner over
// the same socket once the next one is bound, with a fence for the drawing
// that sampled it last.
#include "include/raccoon_view/raccoon_view_plugin.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <flutter_linux/flutter_linux.h>
#include <glib-unix.h>
#include <gtk/gtk.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr uint64_t kModifierInvalid = 0x00ffffffffffffffULL;
// More buffers than a ring will ever have; fences are kept per index.
constexpr int kMaxBuffers = 16;

// One set of buffers as the runner described it, with the descriptors.
struct BufferSet {
  uint32_t generation = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t fourcc = 0;
  uint64_t modifier = 0;
  std::vector<uint32_t> strides;
  std::vector<uint32_t> offsets;
  std::vector<int> fds;
};

struct Imported {
  EGLDisplay display = EGL_NO_DISPLAY;
  uint32_t generation = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<EGLImageKHR> images;
  std::vector<GLuint> textures;
};

// Deletes |imported|'s GL textures and EGL images. Raster thread, Flutter's
// context current.
void destroy_set(Imported& imported) {
  const auto destroy_image = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
      eglGetProcAddress("eglDestroyImageKHR"));
  for (GLuint texture : imported.textures) {
    if (texture != 0) glDeleteTextures(1, &texture);
  }
  for (EGLImageKHR image : imported.images) {
    if (image != EGL_NO_IMAGE_KHR && destroy_image != nullptr) {
      destroy_image(imported.display, image);
    }
  }
  imported.textures.clear();
  imported.images.clear();
}

// Sets of disposed textures: their GL objects belong to Flutter's context,
// current only on the raster thread, so the next populate of any texture
// deletes them. Each holds a ring's buffers until then.
std::mutex graveyard_mutex;
std::vector<std::unique_ptr<Imported>> graveyard;

void bury(std::unique_ptr<Imported> imported) {
  if (!imported) return;
  std::lock_guard<std::mutex> lock(graveyard_mutex);
  graveyard.push_back(std::move(imported));
}

// Raster thread, context current.
void empty_graveyard() {
  std::vector<std::unique_ptr<Imported>> sets;
  {
    std::lock_guard<std::mutex> lock(graveyard_mutex);
    sets.swap(graveyard);
  }
  for (auto& set : sets) destroy_set(*set);
}

}  // namespace

// ---- The texture ---------------------------------------------------------

#define RACCOON_GPU_TEXTURE(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), raccoon_gpu_texture_get_type(), RaccoonGpuTexture))

struct _RaccoonGpuTexture {
  FlTextureGL parent_instance;
  // Marks a frame available, for a set that comes after its frame was named.
  FlTextureRegistrar* registrar;
  std::mutex* mutex;
  // The set waiting to be imported, and the one imported, in Flutter's GL
  // context, which only populate sees.
  std::unique_ptr<BufferSet> pending;
  std::unique_ptr<Imported> imported;
  uint32_t shown_generation;
  int shown_index;
  // The socket's reading state.
  int socket_fd;
  guint watch;
  std::vector<uint8_t> inbox;
  std::vector<int> fds_in_flight;
  EGLDisplay display;
  // The buffer bound through the texture last, -1 for none: given back once
  // another is bound.
  uint32_t bound_generation;
  int bound_index;
  // Each buffer's fence from the runner, by index, -1 for none: signalled
  // when its draw is done.
  uint32_t fence_generations[kMaxBuffers];
  int fence_fds[kMaxBuffers];
  // Native fences on Flutter's display: -1 not looked up yet, else 0 or 1.
  int fences;
  PFNEGLCREATESYNCKHRPROC create_sync;
  PFNEGLDESTROYSYNCKHRPROC destroy_sync;
  PFNEGLWAITSYNCKHRPROC wait_sync;
  PFNEGLCLIENTWAITSYNCKHRPROC client_wait_sync;
  PFNEGLDUPNATIVEFENCEFDANDROIDPROC dup_fence;
};

typedef struct _RaccoonGpuTexture RaccoonGpuTexture;
typedef struct {
  FlTextureGLClass parent_class;
} RaccoonGpuTextureClass;

G_DEFINE_TYPE(RaccoonGpuTexture, raccoon_gpu_texture, fl_texture_gl_get_type())

static void destroy_imported(RaccoonGpuTexture* self) {
  if (!self->imported) return;
  destroy_set(*self->imported);
  self->imported.reset();
}

// ---- Fences --------------------------------------------------------------

// Whether Flutter's display has native fences, looked up once it is known.
// Raster thread.
static bool fences_available(RaccoonGpuTexture* self) {
  if (self->fences >= 0) return self->fences == 1;
  if (self->display == EGL_NO_DISPLAY) return false;
  const char* extensions = eglQueryString(self->display, EGL_EXTENSIONS);
  const auto has = [extensions](const char* name) {
    return extensions != nullptr && std::strstr(extensions, name) != nullptr;
  };
  self->create_sync = reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(
      eglGetProcAddress("eglCreateSyncKHR"));
  self->destroy_sync = reinterpret_cast<PFNEGLDESTROYSYNCKHRPROC>(
      eglGetProcAddress("eglDestroySyncKHR"));
  self->client_wait_sync = reinterpret_cast<PFNEGLCLIENTWAITSYNCKHRPROC>(
      eglGetProcAddress("eglClientWaitSyncKHR"));
  self->dup_fence = reinterpret_cast<PFNEGLDUPNATIVEFENCEFDANDROIDPROC>(
      eglGetProcAddress("eglDupNativeFenceFDANDROID"));
  self->wait_sync = has("EGL_KHR_wait_sync")
                        ? reinterpret_cast<PFNEGLWAITSYNCKHRPROC>(
                              eglGetProcAddress("eglWaitSyncKHR"))
                        : nullptr;
  self->fences = has("EGL_KHR_fence_sync") && has("EGL_ANDROID_native_fence_sync") &&
                         self->create_sync != nullptr && self->destroy_sync != nullptr &&
                         self->client_wait_sync != nullptr && self->dup_fence != nullptr
                     ? 1
                     : 0;
  return self->fences == 1;
}

// Makes Flutter's context wait for |fd| (owned from here) before what it
// draws next. Raster thread, context current.
static void wait_fence(RaccoonGpuTexture* self, int fd) {
  if (!fences_available(self)) {
    close(fd);
    return;
  }
  const EGLint attributes[] = {EGL_SYNC_NATIVE_FENCE_FD_ANDROID, fd, EGL_NONE};
  // The sync owns the descriptor from here.
  const EGLSyncKHR sync =
      self->create_sync(self->display, EGL_SYNC_NATIVE_FENCE_ANDROID, attributes);
  if (sync == EGL_NO_SYNC_KHR) {
    close(fd);
    return;
  }
  if (self->wait_sync != nullptr) {
    self->wait_sync(self->display, sync, 0);
  } else {
    self->client_wait_sync(self->display, sync, 0, EGL_FOREVER_KHR);
  }
  self->destroy_sync(self->display, sync);
}

// A fence for what Flutter's context has drawn so far, -1 without fences.
// Raster thread, context current.
static int export_fence(RaccoonGpuTexture* self) {
  if (!fences_available(self)) return -1;
  const EGLSyncKHR sync =
      self->create_sync(self->display, EGL_SYNC_NATIVE_FENCE_ANDROID, nullptr);
  if (sync == EGL_NO_SYNC_KHR) return -1;
  // The fence is only submitted with the commands before it.
  glFlush();
  const int fd = self->dup_fence(self->display, sync);
  self->destroy_sync(self->display, sync);
  return fd;
}

// Gives buffer |index| of |generation| back to the runner: 'RREL',
// generation, index, fenced, with |fence_fd| (owned from here, -1 for none)
// riding along. Mutex held.
static void send_release(RaccoonGpuTexture* self, uint32_t generation, int index,
                         int fence_fd) {
  if (self->socket_fd < 0) {
    if (fence_fd >= 0) close(fence_fd);
    return;
  }
  uint8_t message[4 + 16] = {16, 0, 0, 0, 'R', 'R', 'E', 'L'};
  const uint32_t values[3] = {generation, static_cast<uint32_t>(index),
                              fence_fd >= 0 ? 1u : 0u};
  for (int v = 0; v < 3; ++v) {
    for (int i = 0; i < 4; ++i) {
      message[8 + v * 4 + i] = static_cast<uint8_t>(values[v] >> (8 * i));
    }
  }
  iovec part{message, sizeof(message)};
  alignas(cmsghdr) uint8_t control[CMSG_SPACE(sizeof(int))];
  std::memset(control, 0, sizeof(control));
  msghdr header{};
  header.msg_iov = &part;
  header.msg_iovlen = 1;
  if (fence_fd >= 0) {
    header.msg_control = control;
    header.msg_controllen = sizeof(control);
    cmsghdr* cmsg = CMSG_FIRSTHDR(&header);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    std::memcpy(CMSG_DATA(cmsg), &fence_fd, sizeof(int));
  }
  sendmsg(self->socket_fd, &header, MSG_NOSIGNAL);
  if (fence_fd >= 0) close(fence_fd);
}

// Closes a fence kept for buffer |index| of |generation|, if any. Mutex held.
static void drop_fence(RaccoonGpuTexture* self, uint32_t generation, int index) {
  if (index < 0 || index >= kMaxBuffers) return;
  if (self->fence_generations[index] != generation || self->fence_fds[index] < 0) return;
  close(self->fence_fds[index]);
  self->fence_fds[index] = -1;
}

// On the raster thread, Flutter's context current. Returns whether a set is
// imported afterwards.
static gboolean import_pending(RaccoonGpuTexture* self, GError** error) {
  std::unique_ptr<BufferSet> set;
  {
    std::lock_guard<std::mutex> lock(*self->mutex);
    // A new ring waits until a frame of it is named: until then the frame
    // shown is of the set at hand, and the new ring's buffers may be being
    // drawn or never drawn.
    if (self->pending &&
        (!self->imported || self->pending->generation == self->shown_generation)) {
      set = std::move(self->pending);
    }
  }
  if (!set) return self->imported != nullptr;
  const auto create_image = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
      eglGetProcAddress("eglCreateImageKHR"));
  const auto target_texture =
      reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
          eglGetProcAddress("glEGLImageTargetTexture2DOES"));
  self->display = eglGetCurrentDisplay();
  if (create_image == nullptr || target_texture == nullptr ||
      self->display == EGL_NO_DISPLAY) {
    for (int fd : set->fds) close(fd);
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                "no EGL image import in this GL context");
    return self->imported != nullptr;
  }
  auto imported = std::make_unique<Imported>();
  imported->display = self->display;
  imported->generation = set->generation;
  imported->width = set->width;
  imported->height = set->height;
  for (size_t i = 0; i < set->fds.size(); ++i) {
    std::vector<EGLint> attributes = {
        EGL_WIDTH, static_cast<EGLint>(set->width),
        EGL_HEIGHT, static_cast<EGLint>(set->height),
        EGL_LINUX_DRM_FOURCC_EXT, static_cast<EGLint>(set->fourcc),
        EGL_DMA_BUF_PLANE0_FD_EXT, set->fds[i],
        EGL_DMA_BUF_PLANE0_OFFSET_EXT, static_cast<EGLint>(set->offsets[i]),
        EGL_DMA_BUF_PLANE0_PITCH_EXT, static_cast<EGLint>(set->strides[i]),
    };
    if (set->modifier != kModifierInvalid) {
      attributes.insert(attributes.end(), {
          EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,
          static_cast<EGLint>(set->modifier & 0xffffffffULL),
          EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,
          static_cast<EGLint>(set->modifier >> 32),
      });
    }
    attributes.push_back(EGL_NONE);
    const EGLImageKHR image =
        create_image(self->display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT,
                     nullptr, attributes.data());
    close(set->fds[i]);  // the image keeps the buffer
    GLuint texture = 0;
    if (image != EGL_NO_IMAGE_KHR) {
      glGenTextures(1, &texture);
      glBindTexture(GL_TEXTURE_2D, texture);
      target_texture(GL_TEXTURE_2D, image);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    imported->images.push_back(image);
    imported->textures.push_back(texture);
  }
  destroy_imported(self);
  self->imported = std::move(imported);
  return TRUE;
}

static gboolean raccoon_gpu_texture_populate(FlTextureGL* texture,
                                             uint32_t* target, uint32_t* name,
                                             uint32_t* width, uint32_t* height,
                                             GError** error) {
  RaccoonGpuTexture* self = RACCOON_GPU_TEXTURE(texture);
  empty_graveyard();
  if (!import_pending(self, error)) {
    // Flutter logs the error's message, and a missing one crashes it.
    if (error != nullptr && *error == nullptr) {
      g_set_error(error, G_IO_ERROR, G_IO_ERROR_PENDING, "no GPU buffers yet");
    }
    return FALSE;
  }
  const Imported& imported = *self->imported;
  if (imported.textures.empty() || imported.textures[0] == 0) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "no GPU buffer imported");
    return FALSE;
  }
  // The frame named is not of this set: the buffer bound last stays, or,
  // with nothing of this set bound yet, the first, and not one to give back.
  int index = 0;
  int fence_fd = -1;
  bool rebound = false;
  uint32_t before_generation = 0;
  int before_index = -1;
  {
    std::lock_guard<std::mutex> lock(*self->mutex);
    const uint32_t generation = self->shown_generation;
    const int shown = self->shown_index;
    if (self->bound_generation == imported.generation && self->bound_index >= 0 &&
        static_cast<size_t>(self->bound_index) < imported.textures.size() &&
        imported.textures[self->bound_index] != 0) {
      index = self->bound_index;
    }
    if (generation == imported.generation && shown >= 0 &&
        static_cast<size_t>(shown) < imported.textures.size() &&
        imported.textures[shown] != 0) {
      index = shown;
      if (shown < kMaxBuffers && self->fence_generations[shown] == generation) {
        fence_fd = self->fence_fds[shown];
        self->fence_fds[shown] = -1;
      }
      rebound = self->bound_index != shown || self->bound_generation != generation;
      before_generation = self->bound_generation;
      before_index = self->bound_index;
      self->bound_generation = generation;
      self->bound_index = shown;
    }
  }
  // The runner's draw may still be running: sample after it.
  if (fence_fd >= 0) wait_fence(self, fence_fd);
  // The buffer bound before was last read by the frame drawn before this
  // one; once that reading is done, it is the runner's again.
  if (rebound && before_index >= 0) {
    const int release_fence = export_fence(self);
    std::lock_guard<std::mutex> lock(*self->mutex);
    send_release(self, before_generation, before_index, release_fence);
  }
  *target = GL_TEXTURE_2D;
  *name = imported.textures[index];
  *width = imported.width;
  *height = imported.height;
  return TRUE;
}

static void raccoon_gpu_texture_dispose(GObject* object) {
  RaccoonGpuTexture* self = RACCOON_GPU_TEXTURE(object);
  if (self->mutex == nullptr) {
    G_OBJECT_CLASS(raccoon_gpu_texture_parent_class)->dispose(object);
    return;
  }
  close_socket(self);
  for (int fd : self->fds_in_flight) close(fd);
  self->fds_in_flight.clear();
  for (int& fd : self->fence_fds) {
    if (fd >= 0) close(fd);
    fd = -1;
  }
  if (self->pending) {
    for (int fd : self->pending->fds) close(fd);
    self->pending.reset();
  }
  bury(std::move(self->imported));
  delete self->mutex;
  self->mutex = nullptr;
  G_OBJECT_CLASS(raccoon_gpu_texture_parent_class)->dispose(object);
}

static void raccoon_gpu_texture_class_init(RaccoonGpuTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = raccoon_gpu_texture_populate;
  G_OBJECT_CLASS(klass)->dispose = raccoon_gpu_texture_dispose;
}

static void raccoon_gpu_texture_init(RaccoonGpuTexture* self) {
  self->registrar = nullptr;
  self->mutex = new std::mutex();
  self->shown_generation = 0;
  self->shown_index = -1;
  self->socket_fd = -1;
  self->watch = 0;
  self->display = EGL_NO_DISPLAY;
  self->bound_generation = 0;
  self->bound_index = -1;
  for (int i = 0; i < kMaxBuffers; ++i) {
    self->fence_generations[i] = 0;
    self->fence_fds[i] = -1;
  }
  self->fences = -1;
  self->create_sync = nullptr;
  self->destroy_sync = nullptr;
  self->wait_sync = nullptr;
  self->client_wait_sync = nullptr;
  self->dup_fence = nullptr;
}

// ---- The GPU socket ------------------------------------------------------

// Stops reading and closes the socket; the raster thread sends releases on
// it under the mutex. Main thread.
static void close_socket(RaccoonGpuTexture* self) {
  if (self->watch != 0) {
    g_source_remove(self->watch);
    self->watch = 0;
  }
  std::lock_guard<std::mutex> lock(*self->mutex);
  if (self->socket_fd >= 0) {
    close(self->socket_fd);
    self->socket_fd = -1;
  }
}

static uint32_t read32(const uint8_t* at) {
  return static_cast<uint32_t>(at[0]) | (static_cast<uint32_t>(at[1]) << 8) |
         (static_cast<uint32_t>(at[2]) << 16) | (static_cast<uint32_t>(at[3]) << 24);
}

static uint64_t read64(const uint8_t* at) {
  return static_cast<uint64_t>(read32(at)) |
         (static_cast<uint64_t>(read32(at + 4)) << 32);
}

// Parses the framed sets in the inbox; the descriptors received so far are
// handed to them in order.
static void parse_inbox(RaccoonGpuTexture* self) {
  size_t offset = 0;
  while (self->inbox.size() - offset >= 4) {
    const uint32_t length = read32(self->inbox.data() + offset);
    if (self->inbox.size() - offset - 4 < length) break;
    const uint8_t* payload = self->inbox.data() + offset + 4;
    offset += 4 + length;
    if (length >= 12 && std::memcmp(payload, "RFEN", 4) == 0) {
      // A frame's fence, one descriptor, kept for its buffer until shown.
      if (self->fds_in_flight.empty()) continue;
      const int fd = self->fds_in_flight.front();
      self->fds_in_flight.erase(self->fds_in_flight.begin());
      const uint32_t generation = read32(payload + 4);
      const uint32_t index = read32(payload + 8);
      std::lock_guard<std::mutex> lock(*self->mutex);
      if (index >= static_cast<uint32_t>(kMaxBuffers)) {
        close(fd);
        continue;
      }
      if (self->fence_fds[index] >= 0) close(self->fence_fds[index]);
      self->fence_fds[index] = fd;
      self->fence_generations[index] = generation;
      continue;
    }
    if (length < 32 || std::memcmp(payload, "RGPU", 4) != 0) continue;
    auto set = std::make_unique<BufferSet>();
    set->generation = read32(payload + 4);
    const uint32_t count = read32(payload + 8);
    set->width = read32(payload + 12);
    set->height = read32(payload + 16);
    set->fourcc = read32(payload + 20);
    set->modifier = read64(payload + 24);
    if (length < 32 + count * 8 || self->fds_in_flight.size() < count) {
      continue;  // not whole, or its descriptors did not all arrive
    }
    for (uint32_t i = 0; i < count; ++i) {
      set->strides.push_back(read32(payload + 32 + i * 8));
      set->offsets.push_back(read32(payload + 36 + i * 8));
      set->fds.push_back(self->fds_in_flight[i]);
    }
    self->fds_in_flight.erase(self->fds_in_flight.begin(),
                              self->fds_in_flight.begin() + count);
    bool named;
    {
      std::lock_guard<std::mutex> lock(*self->mutex);
      if (self->pending) {
        for (int fd : self->pending->fds) close(fd);
      }
      named = set->generation == self->shown_generation;
      self->pending = std::move(set);
    }
    // The frame was named before its set came: Flutter asked for it then
    // and keeps what it got, so it must ask again, or an idle app's pane
    // stays as it was.
    if (named && self->registrar != nullptr) {
      fl_texture_registrar_mark_texture_frame_available(self->registrar, FL_TEXTURE(self));
    }
  }
  self->inbox.erase(self->inbox.begin(), self->inbox.begin() + offset);
}

static gboolean on_socket_readable(gint fd, GIOCondition condition,
                                   gpointer user_data) {
  RaccoonGpuTexture* self = RACCOON_GPU_TEXTURE(user_data);
  uint8_t buffer[16 * 1024];
  alignas(cmsghdr) uint8_t control[CMSG_SPACE(sizeof(int) * 16)];
  iovec part{buffer, sizeof(buffer)};
  msghdr header{};
  header.msg_iov = &part;
  header.msg_iovlen = 1;
  header.msg_control = control;
  header.msg_controllen = sizeof(control);
  const ssize_t got = recvmsg(fd, &header, MSG_CMSG_CLOEXEC);
  for (cmsghdr* cmsg = got > 0 ? CMSG_FIRSTHDR(&header) : nullptr; cmsg != nullptr;
       cmsg = CMSG_NXTHDR(&header, cmsg)) {
    if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS) continue;
    const size_t count = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
    const int* fds = reinterpret_cast<const int*>(CMSG_DATA(cmsg));
    self->fds_in_flight.insert(self->fds_in_flight.end(), fds, fds + count);
  }
  // Hung up, or descriptors were lost (more than fit): the ones after would
  // be matched to the wrong messages, so the socket is done with.
  if (got <= 0 || (header.msg_flags & MSG_CTRUNC) != 0) {
    // The source is removed by returning; close_socket must not remove it.
    self->watch = 0;
    close_socket(self);
    return G_SOURCE_REMOVE;
  }
  self->inbox.insert(self->inbox.end(), buffer, buffer + got);
  parse_inbox(self);
  return G_SOURCE_CONTINUE;
}

static bool connect_socket(RaccoonGpuTexture* self, const std::string& path) {
  const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return false;
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (path.size() >= sizeof(address.sun_path)) {
    close(fd);
    return false;
  }
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  if (connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
    close(fd);
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(*self->mutex);
    self->socket_fd = fd;
  }
  self->watch = g_unix_fd_add(fd, G_IO_IN, on_socket_readable, self);
  return true;
}

// ---- The plugin ----------------------------------------------------------

#define RACCOON_VIEW_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), raccoon_view_plugin_get_type(), RaccoonViewPlugin))

struct _RaccoonViewPlugin {
  GObject parent_instance;
  FlTextureRegistrar* registrar;
  std::map<int64_t, RaccoonGpuTexture*>* textures;
};

G_DEFINE_TYPE(RaccoonViewPlugin, raccoon_view_plugin, g_object_get_type())

static FlMethodResponse* error_response(const char* code, const char* message) {
  return FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
}

static int64_t int_argument(FlValue* args, const char* key, int64_t fallback) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) return fallback;
  return fl_value_get_int(value);
}

static void raccoon_view_plugin_handle_method_call(RaccoonViewPlugin* self,
                                                   FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  if (strcmp(method, "create") == 0) {
    RaccoonGpuTexture* texture =
        RACCOON_GPU_TEXTURE(g_object_new(raccoon_gpu_texture_get_type(), nullptr));
    if (!fl_texture_registrar_register_texture(self->registrar, FL_TEXTURE(texture))) {
      g_object_unref(texture);
      response = error_response("register", "could not register the texture");
    } else {
      const int64_t id = fl_texture_get_id(FL_TEXTURE(texture));
      texture->registrar = self->registrar;
      (*self->textures)[id] = texture;
      g_autoptr(FlValue) result = fl_value_new_int(id);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else {
    const int64_t id = int_argument(args, "textureId", -1);
    const auto found = self->textures->find(id);
    if (found == self->textures->end()) {
      response = error_response("unknown", "no such texture");
    } else if (strcmp(method, "connect") == 0) {
      FlValue* socket = fl_value_lookup_string(args, "socket");
      const char* path = socket != nullptr && fl_value_get_type(socket) == FL_VALUE_TYPE_STRING
                             ? fl_value_get_string(socket)
                             : "";
      if (connect_socket(found->second, path)) {
        // Buffers go back from here, once drawn.
        g_autoptr(FlValue) releases = fl_value_new_bool(TRUE);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(releases));
      } else {
        response = error_response("connect", "could not connect to the GPU socket");
      }
    } else if (strcmp(method, "show") == 0) {
      {
        RaccoonGpuTexture* texture = found->second;
        std::lock_guard<std::mutex> lock(*texture->mutex);
        const auto generation = static_cast<uint32_t>(int_argument(args, "generation", 0));
        const auto index = static_cast<int>(int_argument(args, "index", -1));
        // A frame named but never bound (the raster thread did not get to
        // it) was never read: the runner's again at once.
        const bool superseded = texture->shown_index >= 0 &&
                                (texture->shown_index != index ||
                                 texture->shown_generation != generation);
        const bool unbound = texture->shown_index != texture->bound_index ||
                             texture->shown_generation != texture->bound_generation;
        if (superseded && unbound) {
          drop_fence(texture, texture->shown_generation, texture->shown_index);
          send_release(texture, texture->shown_generation, texture->shown_index, -1);
        }
        texture->shown_generation = generation;
        texture->shown_index = index;
      }
      fl_texture_registrar_mark_texture_frame_available(self->registrar,
                                                        FL_TEXTURE(found->second));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else if (strcmp(method, "dispose") == 0) {
      RaccoonGpuTexture* texture = found->second;
      fl_texture_registrar_unregister_texture(self->registrar, FL_TEXTURE(texture));
      texture->registrar = nullptr;
      // The socket goes now, so the next texture's is not refused; the
      // texture itself a second later, since the registrar hands it to the
      // raster thread without a reference and a populate may be under way.
      close_socket(texture);
      g_timeout_add_seconds(1, [](gpointer data) {
        g_object_unref(data);
        return G_SOURCE_REMOVE;
      }, texture);
      self->textures->erase(found);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    }
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static void raccoon_view_plugin_dispose(GObject* object) {
  RaccoonViewPlugin* self = RACCOON_VIEW_PLUGIN(object);
  // C++14, as Flutter's Linux template builds plugins.
  for (auto& entry : *self->textures) {
    fl_texture_registrar_unregister_texture(self->registrar, FL_TEXTURE(entry.second));
    g_object_unref(entry.second);
  }
  delete self->textures;
  self->textures = nullptr;
  G_OBJECT_CLASS(raccoon_view_plugin_parent_class)->dispose(object);
}

static void raccoon_view_plugin_class_init(RaccoonViewPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = raccoon_view_plugin_dispose;
}

static void raccoon_view_plugin_init(RaccoonViewPlugin* self) {
  self->textures = new std::map<int64_t, RaccoonGpuTexture*>();
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  raccoon_view_plugin_handle_method_call(RACCOON_VIEW_PLUGIN(user_data), method_call);
}

void raccoon_view_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  RaccoonViewPlugin* plugin =
      RACCOON_VIEW_PLUGIN(g_object_new(raccoon_view_plugin_get_type(), nullptr));
  plugin->registrar = fl_plugin_registrar_get_texture_registrar(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "raccoon_view/gpu",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin), g_object_unref);
  g_object_unref(plugin);
}
