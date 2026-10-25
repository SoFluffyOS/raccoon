// The shape of a Flutter Linux plugin, as `flutter create --template=plugin`
// makes one: a GObject, a method channel on the registrar's messenger. The
// answer comes from an idle callback, so it proves the host pumps GLib. The
// `texture` method registers a pixel-buffer texture of one colour, so a
// texture's way through the host's renderer can be seen too, and the `modal`
// method runs a nested main loop for a while.
#include "include/raccoon_echo/raccoon_echo_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>

#define RACCOON_ECHO_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), raccoon_echo_plugin_get_type(), \
                              RaccoonEchoPlugin))

struct _RaccoonEchoPlugin {
  GObject parent_instance;
  FlTextureRegistrar* textures;
  FlTexture* texture;
};

G_DEFINE_TYPE(RaccoonEchoPlugin, raccoon_echo_plugin, g_object_get_type())

// ---- A texture of one colour: orange, 64 by 64 ------------------------------

#define RACCOON_ECHO_TEXTURE(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), raccoon_echo_texture_get_type(), \
                              RaccoonEchoTexture))

struct _RaccoonEchoTexture {
  FlPixelBufferTexture parent_instance;
  uint8_t pixels[64 * 64 * 4];
};
typedef struct _RaccoonEchoTexture RaccoonEchoTexture;
typedef struct {
  FlPixelBufferTextureClass parent_class;
} RaccoonEchoTextureClass;

G_DEFINE_TYPE(RaccoonEchoTexture, raccoon_echo_texture,
              fl_pixel_buffer_texture_get_type())

// On the raster thread; the buffer stays valid until the next copy.
static gboolean copy_pixels(FlPixelBufferTexture* texture, const uint8_t** out_buffer,
                            uint32_t* width, uint32_t* height, GError** error) {
  RaccoonEchoTexture* self = RACCOON_ECHO_TEXTURE(texture);
  *out_buffer = self->pixels;
  *width = 64;
  *height = 64;
  return TRUE;
}

static void raccoon_echo_texture_class_init(RaccoonEchoTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = copy_pixels;
}

static void raccoon_echo_texture_init(RaccoonEchoTexture* self) {
  for (size_t i = 0; i < sizeof(self->pixels); i += 4) {
    self->pixels[i] = 0xFF;      // R
    self->pixels[i + 1] = 0x8C;  // G
    self->pixels[i + 2] = 0x00;  // B
    self->pixels[i + 3] = 0xFF;  // A
  }
}

// ---- The plugin -------------------------------------------------------------

static gboolean reply_from_idle(gpointer data) {
  FlMethodCall* call = FL_METHOD_CALL(data);
  FlValue* args = fl_method_call_get_args(call);
  const gchar* text =
      fl_value_get_type(args) == FL_VALUE_TYPE_STRING ? fl_value_get_string(args) : "?";
  g_autofree gchar* answer = g_strdup_printf("echo: %s", text);
  g_autoptr(FlValue) result = fl_value_new_string(answer);
  fl_method_call_respond_success(call, result, nullptr);
  g_object_unref(call);
  return G_SOURCE_REMOVE;
}

static gboolean mark_frame(gpointer data) {
  RaccoonEchoPlugin* self = RACCOON_ECHO_PLUGIN(data);
  if (self->texture == nullptr) return G_SOURCE_REMOVE;
  fl_texture_registrar_mark_texture_frame_available(self->textures, self->texture);
  return G_SOURCE_CONTINUE;
}

static gboolean quit_loop(gpointer data) {
  g_main_loop_quit(static_cast<GMainLoop*>(data));
  return G_SOURCE_REMOVE;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  RaccoonEchoPlugin* self = RACCOON_ECHO_PLUGIN(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  if (strcmp(method, "echo") == 0) {
    g_idle_add(reply_from_idle, g_object_ref(method_call));
    return;
  }
  if (strcmp(method, "texture") == 0) {
    // Registers the texture once and answers its id; frames are marked
    // every half second so the host keeps drawing it.
    if (self->texture == nullptr) {
      FlTexture* texture =
          FL_TEXTURE(g_object_new(raccoon_echo_texture_get_type(), nullptr));
      if (!fl_texture_registrar_register_texture(self->textures, texture)) {
        g_object_unref(texture);
        fl_method_call_respond_error(method_call, "texture",
                                     "the host took no texture", nullptr, nullptr);
        return;
      }
      self->texture = texture;
      g_timeout_add(500, mark_frame, g_object_ref(self));
      fl_texture_registrar_mark_texture_frame_available(self->textures, texture);
    }
    g_autoptr(FlValue) id = fl_value_new_int(fl_texture_get_id(self->texture));
    fl_method_call_respond_success(method_call, id, nullptr);
    return;
  }
  if (strcmp(method, "modal") == 0) {
    // A nested main loop for the given milliseconds, as a dialog's
    // gtk_dialog_run is until a user closes it: it holds the thread's loop
    // until then. No window, so it runs without a display too.
    FlValue* args = fl_method_call_get_args(method_call);
    const guint ms = fl_value_get_type(args) == FL_VALUE_TYPE_INT
                         ? static_cast<guint>(fl_value_get_int(args))
                         : 1000;
    GMainLoop* loop = g_main_loop_new(nullptr, FALSE);
    g_timeout_add(ms, quit_loop, loop);
    g_main_loop_run(loop);
    g_main_loop_unref(loop);
    g_autoptr(FlValue) done = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(method_call, done, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

static void raccoon_echo_plugin_dispose(GObject* object) {
  RaccoonEchoPlugin* self = RACCOON_ECHO_PLUGIN(object);
  if (self->texture != nullptr) {
    fl_texture_registrar_unregister_texture(self->textures, self->texture);
    g_clear_object(&self->texture);
  }
  g_clear_object(&self->textures);
  G_OBJECT_CLASS(raccoon_echo_plugin_parent_class)->dispose(object);
}

static void raccoon_echo_plugin_class_init(RaccoonEchoPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = raccoon_echo_plugin_dispose;
}

static void raccoon_echo_plugin_init(RaccoonEchoPlugin* self) {}

void raccoon_echo_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  RaccoonEchoPlugin* plugin =
      RACCOON_ECHO_PLUGIN(g_object_new(raccoon_echo_plugin_get_type(), nullptr));
  plugin->textures = FL_TEXTURE_REGISTRAR(
      g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "raccoon_echo", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin), g_object_unref);
  g_object_unref(plugin);
}
