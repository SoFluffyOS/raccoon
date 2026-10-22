// The shape of a Flutter Linux plugin, as `flutter create --template=plugin`
// makes one: a GObject, a method channel on the registrar's messenger. The
// answer comes from an idle callback, so it proves the host pumps GLib.
#include "include/raccoon_echo/raccoon_echo_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>

#define RACCOON_ECHO_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), raccoon_echo_plugin_get_type(), \
                              RaccoonEchoPlugin))

struct _RaccoonEchoPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(RaccoonEchoPlugin, raccoon_echo_plugin, g_object_get_type())

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

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  if (strcmp(fl_method_call_get_name(method_call), "echo") == 0) {
    g_idle_add(reply_from_idle, g_object_ref(method_call));
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

static void raccoon_echo_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(raccoon_echo_plugin_parent_class)->dispose(object);
}

static void raccoon_echo_plugin_class_init(RaccoonEchoPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = raccoon_echo_plugin_dispose;
}

static void raccoon_echo_plugin_init(RaccoonEchoPlugin* self) {}

void raccoon_echo_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  RaccoonEchoPlugin* plugin =
      RACCOON_ECHO_PLUGIN(g_object_new(raccoon_echo_plugin_get_type(), nullptr));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "raccoon_echo", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin), g_object_unref);
  g_object_unref(plugin);
}
