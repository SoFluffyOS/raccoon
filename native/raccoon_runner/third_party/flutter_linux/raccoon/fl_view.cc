// There is no view: the app's window is the client's pane. Plugins that ask
// the registrar for one get NULL; this type exists so the casts in the
// vendored code and in plugins resolve.
//
// The view's getters are here too, answering as for no view. A plugin that
// uses them only on a view it was handed never reaches them, but the loader
// needs every symbol a library names to open it: desktop_drop names
// fl_view_get_engine and fl_view_get_id, and without them it didn't load at
// all. What makes a view or an engine (fl_view_new, fl_engine_new) stays
// out: a plugin that needs one can't work without a window of its own.
#include <gdk/gdk.h>
#include <glib-object.h>
#include <gmodule.h>

extern "C" G_MODULE_EXPORT GType fl_view_get_type(void) {
  static GType type = 0;
  if (type == 0) {
    type = g_type_register_static_simple(G_TYPE_OBJECT, "FlView", sizeof(GObjectClass), nullptr,
                                         sizeof(GObject), nullptr, static_cast<GTypeFlags>(0));
  }
  return type;
}

extern "C" G_MODULE_EXPORT void* fl_view_get_engine(void* view) {
  g_return_val_if_fail(G_TYPE_CHECK_INSTANCE_TYPE(view, fl_view_get_type()), nullptr);
  return nullptr;
}

extern "C" G_MODULE_EXPORT int64_t fl_view_get_id(void* view) {
  g_return_val_if_fail(G_TYPE_CHECK_INSTANCE_TYPE(view, fl_view_get_type()), -1);
  return -1;
}

extern "C" G_MODULE_EXPORT void fl_view_set_background_color(void* view, const GdkRGBA* color) {
  g_return_if_fail(G_TYPE_CHECK_INSTANCE_TYPE(view, fl_view_get_type()));
}
