// There is no view: the app's window is the client's pane. Plugins that ask
// the registrar for one get NULL; this type exists so the casts in the
// vendored code and in plugins resolve.
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
