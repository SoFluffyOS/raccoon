#if RACCOON_HAS_PLUGINS && !defined(__APPLE__) && !defined(_WIN32)
// The Linux half of plugins.h: GObject plugins on the vendored flutter_linux.
#include "plugins.h"

#include <dlfcn.h>
#include <gtk/gtk.h>

#include <cstdio>

#include "flutter/shell/platform/linux/fl_binary_messenger_private.h"
#include "flutter/shell/platform/linux/fl_pixel_buffer_texture_private.h"
#include "flutter/shell/platform/linux/fl_plugin_registrar_private.h"
#include "flutter/shell/platform/linux/fl_texture_gl_private.h"
#include "flutter/shell/platform/linux/fl_texture_registrar_private.h"

namespace raccoon {

PluginHost::PluginHost(Bridge bridge) : bridge_(std::move(bridge)) {
  c_bridge_.send_platform_message = SendPlatformMessage;
  c_bridge_.send_platform_message_response = SendPlatformMessageResponse;
  c_bridge_.register_external_texture = RegisterExternalTexture;
  c_bridge_.mark_texture_frame_available = MarkTextureFrameAvailable;
  c_bridge_.unregister_external_texture = UnregisterExternalTexture;
  engine_ = fl_engine_new_raccoon(&c_bridge_, this);
  messenger_ = fl_binary_messenger_new(engine_);
  textures_ = fl_texture_registrar_new(engine_);
  // No view: the app's window is the client's pane.
  registrar_ = fl_plugin_registrar_new(nullptr, messenger_, textures_);
  // Plugins that open dialogs want GTK up; without a display that is a no.
  if (!gtk_init_check(nullptr, nullptr)) {
    std::fprintf(stderr, "raccoon_runner: no display for GTK; plugins that open windows will not\n");
  }
}

PluginHost::~PluginHost() {
  // The libraries stay mapped: a plugin's objects may outlive this.
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
    std::fprintf(stderr, "raccoon_runner: texture %ld: %s\n", static_cast<long>(texture_id),
                 error->message);
  }
  return ok;
}

void PluginHost::SendPlatformMessage(gpointer user_data, const gchar* channel,
                                     const uint8_t* data, size_t size, FlRaccoonReply reply,
                                     gpointer reply_data) {
  auto* self = static_cast<PluginHost*>(user_data);
  self->bridge_.send(channel, data, size,
                     [reply, reply_data](const uint8_t* answer, size_t answer_size) {
                       reply(answer, answer_size, reply_data);
                     });
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
