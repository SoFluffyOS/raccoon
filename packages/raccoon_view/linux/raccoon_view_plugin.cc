// The host side of Raccoon's GPU buffers on Linux. Dart asks for a texture,
// names the runner's GPU socket, then names each frame's buffer; this side
// takes the buffers' descriptors from that socket, imports them into
// Flutter's own GL context the first time it is asked to populate the
// texture, and from then on populates with the buffer of the latest frame.
//
// Channel raccoon_view/gpu: create() -> textureId; connect(textureId,
// socket); show(textureId, generation, index); dispose(textureId).
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
  uint32_t generation = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<EGLImageKHR> images;
  std::vector<GLuint> textures;
};

}  // namespace

// ---- The texture ---------------------------------------------------------

#define RACCOON_GPU_TEXTURE(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), raccoon_gpu_texture_get_type(), RaccoonGpuTexture))

struct _RaccoonGpuTexture {
  FlTextureGL parent_instance;
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
};

typedef struct _RaccoonGpuTexture RaccoonGpuTexture;
typedef struct {
  FlTextureGLClass parent_class;
} RaccoonGpuTextureClass;

G_DEFINE_TYPE(RaccoonGpuTexture, raccoon_gpu_texture, fl_texture_gl_get_type())

static void destroy_imported(RaccoonGpuTexture* self) {
  if (!self->imported) return;
  const auto destroy_image = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
      eglGetProcAddress("eglDestroyImageKHR"));
  for (GLuint texture : self->imported->textures) {
    if (texture != 0) glDeleteTextures(1, &texture);
  }
  for (EGLImageKHR image : self->imported->images) {
    if (image != EGL_NO_IMAGE_KHR && destroy_image != nullptr) {
      destroy_image(self->display, image);
    }
  }
  self->imported.reset();
}

// On the raster thread, Flutter's context current. Returns whether a set is
// imported afterwards.
static gboolean import_pending(RaccoonGpuTexture* self, GError** error) {
  std::unique_ptr<BufferSet> set;
  {
    std::lock_guard<std::mutex> lock(*self->mutex);
    set = std::move(self->pending);
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
  if (!import_pending(self, error)) return FALSE;
  uint32_t generation = 0;
  int index = 0;
  {
    std::lock_guard<std::mutex> lock(*self->mutex);
    generation = self->shown_generation;
    index = self->shown_index;
  }
  const Imported& imported = *self->imported;
  if (generation != imported.generation || index < 0 ||
      static_cast<size_t>(index) >= imported.textures.size() ||
      imported.textures[index] == 0) {
    // Nothing of this set shown yet: the first buffer, rather than nothing.
    index = 0;
    if (imported.textures.empty() || imported.textures[0] == 0) {
      g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "no GPU buffer imported");
      return FALSE;
    }
  }
  *target = GL_TEXTURE_2D;
  *name = imported.textures[index];
  *width = imported.width;
  *height = imported.height;
  return TRUE;
}

static void raccoon_gpu_texture_dispose(GObject* object) {
  RaccoonGpuTexture* self = RACCOON_GPU_TEXTURE(object);
  if (self->watch != 0) {
    g_source_remove(self->watch);
    self->watch = 0;
  }
  if (self->socket_fd >= 0) {
    close(self->socket_fd);
    self->socket_fd = -1;
  }
  for (int fd : self->fds_in_flight) close(fd);
  self->fds_in_flight.clear();
  if (self->pending) {
    for (int fd : self->pending->fds) close(fd);
    self->pending.reset();
  }
  // The GL objects of an imported set belong to Flutter's context, gone
  // with it; the images are released when the display is.
  self->imported.reset();
  delete self->mutex;
  self->mutex = nullptr;
  G_OBJECT_CLASS(raccoon_gpu_texture_parent_class)->dispose(object);
}

static void raccoon_gpu_texture_class_init(RaccoonGpuTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = raccoon_gpu_texture_populate;
  G_OBJECT_CLASS(klass)->dispose = raccoon_gpu_texture_dispose;
}

static void raccoon_gpu_texture_init(RaccoonGpuTexture* self) {
  self->mutex = new std::mutex();
  self->shown_generation = 0;
  self->shown_index = -1;
  self->socket_fd = -1;
  self->watch = 0;
  self->display = EGL_NO_DISPLAY;
}

// ---- The GPU socket ------------------------------------------------------

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
    std::lock_guard<std::mutex> lock(*self->mutex);
    if (self->pending) {
      for (int fd : self->pending->fds) close(fd);
    }
    self->pending = std::move(set);
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
  if (got <= 0) {
    self->watch = 0;
    close(self->socket_fd);
    self->socket_fd = -1;
    return G_SOURCE_REMOVE;
  }
  for (cmsghdr* cmsg = CMSG_FIRSTHDR(&header); cmsg != nullptr;
       cmsg = CMSG_NXTHDR(&header, cmsg)) {
    if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS) continue;
    const size_t count = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
    const int* fds = reinterpret_cast<const int*>(CMSG_DATA(cmsg));
    self->fds_in_flight.insert(self->fds_in_flight.end(), fds, fds + count);
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
  self->socket_fd = fd;
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
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      } else {
        response = error_response("connect", "could not connect to the GPU socket");
      }
    } else if (strcmp(method, "show") == 0) {
      {
        std::lock_guard<std::mutex> lock(*found->second->mutex);
        found->second->shown_generation =
            static_cast<uint32_t>(int_argument(args, "generation", 0));
        found->second->shown_index = static_cast<int>(int_argument(args, "index", -1));
      }
      fl_texture_registrar_mark_texture_frame_available(self->registrar,
                                                        FL_TEXTURE(found->second));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else if (strcmp(method, "dispose") == 0) {
      fl_texture_registrar_unregister_texture(self->registrar, FL_TEXTURE(found->second));
      g_object_unref(found->second);
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
  for (auto& [id, texture] : *self->textures) {
    fl_texture_registrar_unregister_texture(self->registrar, FL_TEXTURE(texture));
    g_object_unref(texture);
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
