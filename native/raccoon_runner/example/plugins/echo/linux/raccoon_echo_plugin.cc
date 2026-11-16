// The shape of a Flutter Linux plugin, as `flutter create --template=plugin`
// makes one: a GObject, a method channel on the registrar's messenger. The
// answer comes from an idle callback, so it proves the host pumps GLib. The
// `texture` method registers a pixel-buffer texture of one colour, so a
// texture's way through the host's renderer can be seen too, and the `modal`
// method runs a nested main loop for a while. `churn` lets textures go while
// their frames draw, and `churn_report` says what became of them.
#include "include/raccoon_echo/raccoon_echo_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <dlfcn.h>

#include <cstring>

#define RACCOON_ECHO_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), raccoon_echo_plugin_get_type(), \
                              RaccoonEchoPlugin))

struct _RaccoonEchoPlugin {
  GObject parent_instance;
  FlTextureRegistrar* textures;
  FlTexture* texture;
  // The churn texture registered last, until it is let go, and a `churned`
  // call waiting for that.
  FlTexture* churn_texture;
  FlMethodCall* churned_call;
  guint churned_timeout;
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

// ---- Churn: textures let go while their frame draws (#123) -----------------
// A churn texture's second copy, on the raster thread, has the plugin
// unregister it and drop its reference on the platform thread, and waits
// until it has (a second at most), as a plugin letting a texture go while a
// frame draws it would. What became of them all is counted: one finalized
// while its frame was still being populated was used after it was freed, and
// one disposed with no GL context current left its GL name behind. A host
// keeps both at none.

namespace {

GMutex churn_mutex;
GCond churn_cond;
struct {
  int made;
  int populated;
  int finalized;
  int finalized_in_populate;
  int no_context;
} churn_counts;
// The texture whose copy waits for its plugin to let it go; only compared.
gpointer churn_waiting = nullptr;
gboolean churn_let_go = FALSE;
// Blue, 64 by 64: what every churn texture shows.
uint8_t churn_pixels[64 * 64 * 4];

// The GL context current on this thread, if any; EGL is the host's.
bool gl_context_current() {
  using Current = void* (*)();
  static const auto current =
      reinterpret_cast<Current>(dlsym(RTLD_DEFAULT, "eglGetCurrentContext"));
  return current != nullptr && current() != nullptr;
}

}  // namespace

#define RACCOON_CHURN_TEXTURE(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), raccoon_churn_texture_get_type(), \
                              RaccoonChurnTexture))

struct _RaccoonChurnTexture {
  FlPixelBufferTexture parent_instance;
  RaccoonEchoPlugin* plugin;  // not owned: it outlives its textures
  int copies;                 // raster thread only
};
typedef struct _RaccoonChurnTexture RaccoonChurnTexture;
typedef struct {
  FlPixelBufferTextureClass parent_class;
} RaccoonChurnTextureClass;

G_DEFINE_TYPE(RaccoonChurnTexture, raccoon_churn_texture,
              fl_pixel_buffer_texture_get_type())

static void answer_churned(RaccoonEchoPlugin* self, const gchar* how) {
  if (self->churned_timeout != 0) {
    g_source_remove(self->churned_timeout);
    self->churned_timeout = 0;
  }
  if (self->churned_call == nullptr) return;
  g_autoptr(FlValue) result = fl_value_new_string(how);
  fl_method_call_respond_success(self->churned_call, result, nullptr);
  g_clear_object(&self->churned_call);
}

// Platform thread: lets the churn texture go, as its plugin would.
static gboolean churn_let_go_cb(gpointer data) {
  RaccoonEchoPlugin* self = RACCOON_ECHO_PLUGIN(data);
  if (self->churn_texture != nullptr) {
    fl_texture_registrar_unregister_texture(self->textures, self->churn_texture);
    g_clear_object(&self->churn_texture);
  }
  g_mutex_lock(&churn_mutex);
  churn_let_go = TRUE;
  g_cond_broadcast(&churn_cond);
  g_mutex_unlock(&churn_mutex);
  answer_churned(self, "let go");
  return G_SOURCE_REMOVE;
}

// Platform thread: a second frame for the churn texture.
static gboolean churn_mark_cb(gpointer data) {
  RaccoonEchoPlugin* self = RACCOON_ECHO_PLUGIN(data);
  if (self->churn_texture != nullptr) {
    fl_texture_registrar_mark_texture_frame_available(self->textures, self->churn_texture);
  }
  return G_SOURCE_REMOVE;
}

// Raster thread. Nothing of the texture is touched after the wait: before
// #123's fix it could be gone by then.
static gboolean churn_copy_pixels(FlPixelBufferTexture* texture, const uint8_t** out_buffer,
                                  uint32_t* width, uint32_t* height, GError** error) {
  RaccoonChurnTexture* self = RACCOON_CHURN_TEXTURE(texture);
  RaccoonEchoPlugin* plugin = self->plugin;
  const int copy = ++self->copies;
  if (copy == 1) {
    g_main_context_invoke(nullptr, churn_mark_cb, plugin);
  } else if (copy == 2) {
    g_mutex_lock(&churn_mutex);
    churn_waiting = self;
    churn_let_go = FALSE;
    g_main_context_invoke(nullptr, churn_let_go_cb, plugin);
    const gint64 until = g_get_monotonic_time() + G_TIME_SPAN_SECOND;
    while (!churn_let_go && g_cond_wait_until(&churn_cond, &churn_mutex, until)) {
    }
    churn_waiting = nullptr;
    g_mutex_unlock(&churn_mutex);
  }
  g_mutex_lock(&churn_mutex);
  ++churn_counts.populated;
  g_mutex_unlock(&churn_mutex);
  *out_buffer = churn_pixels;
  *width = 64;
  *height = 64;
  return TRUE;
}

static void raccoon_churn_texture_dispose(GObject* object) {
  if (!gl_context_current()) {
    g_mutex_lock(&churn_mutex);
    ++churn_counts.no_context;
    g_mutex_unlock(&churn_mutex);
  }
  G_OBJECT_CLASS(raccoon_churn_texture_parent_class)->dispose(object);
}

static void raccoon_churn_texture_finalize(GObject* object) {
  g_mutex_lock(&churn_mutex);
  ++churn_counts.finalized;
  if (churn_waiting == object) ++churn_counts.finalized_in_populate;
  g_mutex_unlock(&churn_mutex);
  G_OBJECT_CLASS(raccoon_churn_texture_parent_class)->finalize(object);
}

static void raccoon_churn_texture_class_init(RaccoonChurnTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = churn_copy_pixels;
  G_OBJECT_CLASS(klass)->dispose = raccoon_churn_texture_dispose;
  G_OBJECT_CLASS(klass)->finalize = raccoon_churn_texture_finalize;
}

static void raccoon_churn_texture_init(RaccoonChurnTexture* self) {
  self->plugin = nullptr;
  self->copies = 0;
}

static gboolean churned_timeout_cb(gpointer data) {
  RaccoonEchoPlugin* self = RACCOON_ECHO_PLUGIN(data);
  self->churned_timeout = 0;
  answer_churned(self, "timed out");
  return G_SOURCE_REMOVE;
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
  if (strcmp(method, "churn") == 0) {
    // A new churn texture; the one before is let go if it was not yet.
    churn_let_go_cb(self);
    RaccoonChurnTexture* texture = RACCOON_CHURN_TEXTURE(
        g_object_new(raccoon_churn_texture_get_type(), nullptr));
    texture->plugin = self;
    if (!fl_texture_registrar_register_texture(self->textures, FL_TEXTURE(texture))) {
      g_object_unref(texture);
      fl_method_call_respond_error(method_call, "churn", "the host took no texture",
                                   nullptr, nullptr);
      return;
    }
    self->churn_texture = FL_TEXTURE(texture);
    g_mutex_lock(&churn_mutex);
    ++churn_counts.made;
    g_mutex_unlock(&churn_mutex);
    fl_texture_registrar_mark_texture_frame_available(self->textures, self->churn_texture);
    g_autoptr(FlValue) id = fl_value_new_int(fl_texture_get_id(self->churn_texture));
    fl_method_call_respond_success(method_call, id, nullptr);
    return;
  }
  if (strcmp(method, "churned") == 0) {
    // Answers once the churn texture is let go, or after two seconds.
    if (self->churn_texture == nullptr) {
      g_autoptr(FlValue) result = fl_value_new_string("let go");
      fl_method_call_respond_success(method_call, result, nullptr);
      return;
    }
    answer_churned(self, "replaced");
    self->churned_call = FL_METHOD_CALL(g_object_ref(method_call));
    self->churned_timeout = g_timeout_add_full(G_PRIORITY_DEFAULT, 2000, churned_timeout_cb,
                                               g_object_ref(self), g_object_unref);
    return;
  }
  if (strcmp(method, "churn_report") == 0) {
    g_mutex_lock(&churn_mutex);
    g_autofree gchar* report = g_strdup_printf(
        "made=%d populated=%d finalized=%d finalized_in_populate=%d no_context=%d",
        churn_counts.made, churn_counts.populated, churn_counts.finalized,
        churn_counts.finalized_in_populate, churn_counts.no_context);
    g_mutex_unlock(&churn_mutex);
    g_autoptr(FlValue) result = fl_value_new_string(report);
    fl_method_call_respond_success(method_call, result, nullptr);
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
  if (self->churn_texture != nullptr) {
    fl_texture_registrar_unregister_texture(self->textures, self->churn_texture);
    g_clear_object(&self->churn_texture);
  }
  answer_churned(self, "gone");
  g_clear_object(&self->textures);
  G_OBJECT_CLASS(raccoon_echo_plugin_parent_class)->dispose(object);
}

static void raccoon_echo_plugin_class_init(RaccoonEchoPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = raccoon_echo_plugin_dispose;
}

static void raccoon_echo_plugin_init(RaccoonEchoPlugin* self) {
  self->textures = nullptr;
  self->texture = nullptr;
  self->churn_texture = nullptr;
  self->churned_call = nullptr;
  self->churned_timeout = 0;
  for (size_t i = 0; i < sizeof(churn_pixels); i += 4) {
    churn_pixels[i] = 0x15;      // R
    churn_pixels[i + 1] = 0x65;  // G
    churn_pixels[i + 2] = 0xC0;  // B
    churn_pixels[i + 3] = 0xFF;  // A
  }
}

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
