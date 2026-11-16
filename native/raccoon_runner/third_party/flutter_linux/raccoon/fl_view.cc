// There is no view by default: the app's window is the client's pane.
// Plugins that ask the registrar for one get NULL; this type exists so the
// casts in the vendored code and in plugins resolve.
//
// The view's getters are here too, answering as for no view. A plugin that
// uses them only on a view it was handed never reaches them, but the loader
// needs every symbol a library names to open it: desktop_drop names
// fl_view_get_engine and fl_view_get_id, and without them it didn't load at
// all. What makes a view or an engine (fl_view_new, fl_engine_new) stays
// out: a plugin that needs one can't work without a window of its own.
//
// RACCOON_PLUGIN_VIEW=1 (Linux, a spike): the runner's plugin view library
// registers a real FlView, a GtkBox in a hidden toplevel per view, and
// hands its type here before any plugin asks, with
// fl_view_raccoon_use_type. The getters then answer what it set on each
// view. This library still calls no GTK: it is loaded whether or not a
// plugin uses GTK (#223).
#include <gdk/gdk.h>
#include <glib-object.h>
#include <gmodule.h>

namespace {

GType provided_type = 0;

}  // namespace

// The FlView type to use in place of the stub, from the plugin view
// library; FALSE once the stub was registered, too late to change.
extern "C" G_MODULE_EXPORT gboolean fl_view_raccoon_use_type(GType type);

extern "C" G_MODULE_EXPORT GType fl_view_get_type(void) {
  static GType type = 0;
  if (type == 0) {
    type = provided_type != 0
               ? provided_type
               : g_type_register_static_simple(G_TYPE_OBJECT, "FlView", sizeof(GObjectClass),
                                               nullptr, sizeof(GObject), nullptr,
                                               static_cast<GTypeFlags>(0));
  }
  return type;
}

extern "C" G_MODULE_EXPORT gboolean fl_view_raccoon_use_type(GType type) {
  if (g_type_from_name("FlView") != 0 && g_type_from_name("FlView") != type) return FALSE;
  provided_type = type;
  return fl_view_get_type() == type;
}

extern "C" G_MODULE_EXPORT void* fl_view_get_engine(void* view) {
  g_return_val_if_fail(G_TYPE_CHECK_INSTANCE_TYPE(view, fl_view_get_type()), nullptr);
  return g_object_get_data(G_OBJECT(view), "raccoon-engine");
}

extern "C" G_MODULE_EXPORT int64_t fl_view_get_id(void* view) {
  g_return_val_if_fail(G_TYPE_CHECK_INSTANCE_TYPE(view, fl_view_get_type()), -1);
  gpointer id = g_object_get_data(G_OBJECT(view), "raccoon-view-id");
  // Stored as id + 1, so view 0 is not NULL.
  return id == nullptr ? -1 : static_cast<int64_t>(GPOINTER_TO_SIZE(id)) - 1;
}

extern "C" G_MODULE_EXPORT void fl_view_set_background_color(void* view, const GdkRGBA* color) {
  g_return_if_fail(G_TYPE_CHECK_INSTANCE_TYPE(view, fl_view_get_type()));
}
