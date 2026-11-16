#if RACCOON_HAS_PLUGINS && !defined(__APPLE__) && !defined(_WIN32)
// The Linux half of plugins.h: GObject plugins on the vendored flutter_linux.
#include "plugins.h"

#include <dlfcn.h>
#include <glib-object.h>
#include <limits.h>
#include <stdlib.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

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

struct PluginHost::PluginView {
  gboolean (*start)();
  GObject* (*add)(int64_t id, FlEngine* engine, int width, int height);
  void (*resize)(int64_t id, int width, int height);
  void (*remove)(int64_t id);
};

bool PluginHost::PluginViewWanted() {
  const char* wanted = std::getenv("RACCOON_PLUGIN_VIEW");
  return wanted != nullptr && std::strcmp(wanted, "1") == 0;
}

namespace {

// libraccoon_plugin_view.so, beside the real libflutter_linux_gtk.so (the
// app's executable has a link to it), opened global before any plugin so
// its window calls come before GTK's; null, said once, when it can't be
// or GTK has no display.
const PluginHost::PluginView* OpenPluginView() {
  static bool tried = false;
  static PluginHost::PluginView view{};
  if (tried) return view.start != nullptr ? &view : nullptr;
  tried = true;
  const gint64 start = g_get_monotonic_time();
  Dl_info info{};
  std::string dir;
  char resolved[PATH_MAX];
  if (dladdr(reinterpret_cast<void*>(&fl_engine_new_raccoon), &info) != 0 &&
      info.dli_fname != nullptr && realpath(info.dli_fname, resolved) != nullptr) {
    dir = resolved;
    dir.resize(dir.rfind('/'));
  }
  const std::string library = dir + "/libraccoon_plugin_view.so";
  void* handle = dlopen(library.c_str(), RTLD_NOW | RTLD_GLOBAL);
  if (handle == nullptr) {
    std::fprintf(stderr, "🦝 plugin view: %s\n", dlerror());
    return nullptr;
  }
  PluginHost::PluginView found{
      reinterpret_cast<gboolean (*)()>(dlsym(handle, "raccoon_plugin_view_start")),
      reinterpret_cast<GObject* (*)(int64_t, FlEngine*, int, int)>(
          dlsym(handle, "raccoon_plugin_view_add")),
      reinterpret_cast<void (*)(int64_t, int, int)>(dlsym(handle, "raccoon_plugin_view_resize")),
      reinterpret_cast<void (*)(int64_t)>(dlsym(handle, "raccoon_plugin_view_remove"))};
  if (found.start == nullptr || found.add == nullptr || found.resize == nullptr ||
      found.remove == nullptr) {
    std::fprintf(stderr, "🦝 plugin view: %s lacks its calls\n", library.c_str());
    return nullptr;
  }
  if (!found.start()) return nullptr;
  view = found;
  std::fprintf(stderr, "🦝 plugin view: on, %.1f ms\n", (g_get_monotonic_time() - start) / 1000.0);
  return &view;
}

int Logical(size_t physical, double pixel_ratio) {
  return static_cast<int>(std::lround(static_cast<double>(physical) /
                                      (pixel_ratio > 0 ? pixel_ratio : 1.0)));
}

}  // namespace

void PluginHost::ViewSized(int64_t view, size_t width, size_t height, double pixel_ratio) {
  if (plugin_view_ == nullptr) return;
  plugin_view_->add(view, engine_, Logical(width, pixel_ratio), Logical(height, pixel_ratio));
  plugin_view_->resize(view, Logical(width, pixel_ratio), Logical(height, pixel_ratio));
}

void PluginHost::ViewRemoved(int64_t view) {
  if (plugin_view_ != nullptr) plugin_view_->remove(view);
}

PluginHost::PluginHost(Bridge bridge) : bridge_(std::move(bridge)) {
  c_bridge_.send_platform_message = SendPlatformMessage;
  c_bridge_.send_platform_message_response = SendPlatformMessageResponse;
  c_bridge_.register_external_texture = RegisterExternalTexture;
  c_bridge_.mark_texture_frame_available = MarkTextureFrameAvailable;
  c_bridge_.unregister_external_texture = UnregisterExternalTexture;
  engine_ = fl_engine_new_raccoon(&c_bridge_, this);
  messenger_ = FL_BINARY_MESSENGER(g_object_ref(fl_engine_get_binary_messenger(engine_)));
  textures_ = FL_TEXTURE_REGISTRAR(g_object_ref(fl_engine_get_texture_registrar(engine_)));
  // No view: the app's window is the client's pane. Unless
  // RACCOON_PLUGIN_VIEW=1 gives plugins a hidden one, view 0's, at a size
  // the host's first resize replaces.
  GObject* view = nullptr;
  if (PluginViewWanted()) {
    plugin_view_ = OpenPluginView();
    if (plugin_view_ != nullptr) view = plugin_view_->add(0, engine_, 800, 600);
  }
  registrar_ = fl_plugin_registrar_new(reinterpret_cast<FlView*>(view), messenger_, textures_);
}

PluginHost::~PluginHost() {
  // The libraries stay mapped: a plugin's objects may outlive this, and the
  // engine with them, which a plugin thread or a reply still to come can
  // keep. What they call on it from now on does nothing.
  fl_engine_raccoon_detach(engine_);
  // The views' toplevels stay: a plugin may hold one, and GTK with it.
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
  // Global, as a desktop app's executable links its plugins: their symbols
  // are the process's. sqlite3 looks for sqlite3_flutter_libs' build there
  // (DynamicLibrary.executable()), and with RTLD_LOCAL fell back to a
  // libsqlite3.so the system may not have (#363).
  void* handle = dlopen(entry.library.c_str(), RTLD_NOW | RTLD_GLOBAL);
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
  // A reference of the populate's own: the plugin may let the texture go
  // on its thread meanwhile. Until it is taken the registrar's holds, as
  // an unregister takes one of ours before the registrar drops its own
  // (UnregisterExternalTexture), so the pointer the lookup gave stays good
  // (#123).
  FlTexture* found = fl_texture_registrar_lookup_texture(textures_, texture_id);
  if (found == nullptr) return false;
  g_autoptr(FlTexture) texture = FL_TEXTURE(g_object_ref(found));
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
  auto* self = static_cast<PluginHost*>(user_data);
  // Still the registrar's here: it drops its reference once this returns.
  // One of ours keeps the texture to the raster thread, after what the
  // engine has queued there: a populate under way finishes with it, and
  // the texture goes there, the GL context current, so a pixel-buffer
  // texture's GL name is deleted in it rather than wherever the plugin
  // let go (#123). fl_texture_registrar_unregister_texture calls this
  // before it takes the texture out of its table.
  FlTexture* texture = fl_texture_registrar_lookup_texture(self->textures_, texture_id);
  if (texture != nullptr) g_object_ref(texture);
  const gboolean ok = self->bridge_.unregister_texture(texture_id);
  if (texture != nullptr &&
      !(self->bridge_.post_render_task &&
        self->bridge_.post_render_task([texture] { g_object_unref(texture); }))) {
    // No engine to run it, and none to draw the texture either.
    g_object_unref(texture);
  }
  return ok;
}

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS && !__APPLE__ && !_WIN32
