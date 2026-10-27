#if RACCOON_HAS_PLUGINS && !defined(__APPLE__) && !defined(_WIN32)
// The Linux half of plugins.h: GObject plugins on the vendored flutter_linux.
#include "plugins.h"

#include <dlfcn.h>
#include <glib-object.h>

#include <cstdio>

#include "flutter/shell/platform/linux/fl_binary_messenger_private.h"
#include "flutter/shell/platform/linux/fl_pixel_buffer_texture_private.h"
#include "flutter/shell/platform/linux/fl_plugin_registrar_private.h"
#include "flutter/shell/platform/linux/fl_texture_gl_private.h"
#include "flutter/shell/platform/linux/fl_texture_registrar_private.h"

namespace raccoon {

namespace {

// GTK, set up once a plugin's library has brought it in, before that
// plugin registers: plugins that open dialogs want it up. The runner itself
// does not link it, so an app whose plugins don't use it never loads it
// (#223).
void InitGtkIfLoaded() {
  static bool done = false;
  if (done) return;
  void* gtk = dlopen("libgtk-3.so.0", RTLD_NOW | RTLD_NOLOAD);
  if (gtk == nullptr) return;
  done = true;
  using InitCheck = int (*)(int*, char***);
  auto init = reinterpret_cast<InitCheck>(dlsym(gtk, "gtk_init_check"));
  if (init == nullptr || !init(nullptr, nullptr)) {
    std::fprintf(stderr, "🦝 no display for GTK; plugins that open windows will not\n");
  }
}

}  // namespace

PluginHost::PluginHost(Bridge bridge) : bridge_(std::move(bridge)) {
  c_bridge_.send_platform_message = SendPlatformMessage;
  c_bridge_.send_platform_message_response = SendPlatformMessageResponse;
  c_bridge_.register_external_texture = RegisterExternalTexture;
  c_bridge_.mark_texture_frame_available = MarkTextureFrameAvailable;
  c_bridge_.unregister_external_texture = UnregisterExternalTexture;
  engine_ = fl_engine_new_raccoon(&c_bridge_, this);
  messenger_ = FL_BINARY_MESSENGER(g_object_ref(fl_engine_get_binary_messenger(engine_)));
  textures_ = FL_TEXTURE_REGISTRAR(g_object_ref(fl_engine_get_texture_registrar(engine_)));
  // No view: the app's window is the client's pane.
  registrar_ = fl_plugin_registrar_new(nullptr, messenger_, textures_);
}

PluginHost::~PluginHost() {
  // The libraries stay mapped: a plugin's objects may outlive this, and the
  // engine with them, which a plugin thread or a reply still to come can
  // keep. What they call on it from now on does nothing.
  fl_engine_raccoon_detach(engine_);
  g_clear_object(&registrar_);
  g_clear_object(&textures_);
  g_clear_object(&messenger_);
  g_clear_object(&engine_);
}

bool PluginHost::Prepare(const std::string&, std::string*) {
  // Plugins link against the library beside the runner, already loaded.
  return true;
}

bool PluginHost::Load(const PluginEntry& entry, std::string* error) {
  if (entry.library.empty() || entry.symbol.empty()) {
    *error = "no library or symbol";
    return false;
  }
  void* handle = dlopen(entry.library.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (handle == nullptr) {
    *error = dlerror();
    return false;
  }
  using Register = void (*)(FlPluginRegistrar*);
  auto register_plugin = reinterpret_cast<Register>(dlsym(handle, entry.symbol.c_str()));
  if (register_plugin == nullptr) {
    *error = "no " + entry.symbol + " in " + entry.library;
    return false;
  }
  handles_.push_back(handle);
  InitGtkIfLoaded();
  register_plugin(registrar_);
  names_.push_back(entry.name);
  return true;
}

bool PluginHost::HandleMessage(const std::string& channel, const uint8_t* data, size_t size,
                               const FlutterPlatformMessageResponseHandle* handle) {
  return fl_engine_raccoon_handle_platform_message(engine_, channel.c_str(), data, size, handle);
}

bool PluginHost::PopulateTexture(int64_t texture_id, size_t width, size_t height,
                                 FlutterOpenGLTexture* out) {
  FlTexture* texture = fl_texture_registrar_lookup_texture(textures_, texture_id);
  if (texture == nullptr) return false;
  g_autoptr(GError) error = nullptr;
  gboolean ok = FALSE;
  if (FL_IS_TEXTURE_GL(texture)) {
    ok = fl_texture_gl_populate(FL_TEXTURE_GL(texture), static_cast<uint32_t>(width),
                                static_cast<uint32_t>(height), out, &error);
  } else if (FL_IS_PIXEL_BUFFER_TEXTURE(texture)) {
    ok = fl_pixel_buffer_texture_populate(FL_PIXEL_BUFFER_TEXTURE(texture),
                                          static_cast<uint32_t>(width),
                                          static_cast<uint32_t>(height), out, &error);
  }
  if (!ok && error != nullptr) {
    std::fprintf(stderr, "🦝 texture %ld: %s\n", static_cast<long>(texture_id),
                 error->message);
  }
  return ok;
}

void PluginHost::SendPlatformMessage(gpointer user_data, const gchar* channel,
                                     const uint8_t* data, size_t size, FlRaccoonReply reply,
                                     gpointer reply_data) {
  auto* self = static_cast<PluginHost*>(user_data);
  std::function<void(const uint8_t*, size_t)> on_reply;
  if (reply != nullptr) {
    on_reply = [reply, reply_data](const uint8_t* answer, size_t answer_size) {
      reply(answer, answer_size, reply_data);
    };
  }
  self->bridge_.send(channel, data, size, std::move(on_reply));
}

gboolean PluginHost::SendPlatformMessageResponse(
    gpointer user_data, const FlutterPlatformMessageResponseHandle* handle,
    const uint8_t* data, size_t size) {
  static_cast<PluginHost*>(user_data)->bridge_.respond(handle, data, size);
  return TRUE;
}

gboolean PluginHost::RegisterExternalTexture(gpointer user_data, int64_t texture_id) {
  return static_cast<PluginHost*>(user_data)->bridge_.register_texture(texture_id);
}

gboolean PluginHost::MarkTextureFrameAvailable(gpointer user_data, int64_t texture_id) {
  return static_cast<PluginHost*>(user_data)->bridge_.mark_texture_frame_available(texture_id);
}

gboolean PluginHost::UnregisterExternalTexture(gpointer user_data, int64_t texture_id) {
  return static_cast<PluginHost*>(user_data)->bridge_.unregister_texture(texture_id);
}

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS && !__APPLE__ && !_WIN32
