// The plugin view (RACCOON_PLUGIN_VIEW=1, Linux, a spike): for each of the
// app's views a GTK toplevel, realized and never shown, holding the
// registrar's FlView, so plugins that want a view's widget, its GdkWindow
// or its toplevel find one. The app's window is still the client's pane:
// this one is never on screen.
//
// Built as a library of its own, libraccoon_plugin_view.so, linked to GTK
// and opened by the runner only when the variable asks for it, global and
// before any plugin: GTK comes in with it, and the calls below that show,
// present, move or resize a window come before GTK's for every library
// opened after it (plugins, and what Dart opens by FFI). On the toplevels
// here a show or a present is refused and said so; a move, a resize or a
// full screen is passed to GTK, which records it for a window that isn't
// mapped, and said so. The host's size wins at its next resize.
#include <dlfcn.h>
#include <gtk/gtk.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <map>
#include <mutex>

#include "flutter/shell/platform/linux/public/flutter_linux/fl_engine.h"

extern "C" gboolean fl_view_raccoon_use_type(GType type);

namespace {

struct FlViewInstance {
  GtkBox parent_instance;
};
struct FlViewClassStruct {
  GtkBoxClass parent_class;
};

GType RegisterFlView() {
  static GType type = 0;
  if (type == 0) {
    type = g_type_register_static_simple(
        GTK_TYPE_BOX, "FlView", sizeof(FlViewClassStruct), nullptr, sizeof(FlViewInstance),
        nullptr, static_cast<GTypeFlags>(0));
  }
  return type;
}

struct View {
  int64_t id = 0;
  GtkWidget* window = nullptr;
  GtkWidget* view = nullptr;
  GdkWindow* gdk_window = nullptr;
  int width = 0;
  int height = 0;
};

std::map<int64_t, View>& Views() {
  static std::map<int64_t, View> views;
  return views;
}

// The views are the main thread's; a plugin's call may come from another
// (an FFI call runs on the UI thread), so the lookups below hold this.
std::mutex views_mutex;

bool started = false;
// While the library itself sizes or shows a window on this thread: its own
// calls are not a plugin's.
thread_local int own_calls = 0;

// The id of the view whose toplevel is |window|, or -1.
int64_t ViewOfWindow(gpointer window) {
  if (window == nullptr) return -1;
  std::lock_guard<std::mutex> lock(views_mutex);
  for (const auto& [id, view] : Views()) {
    if (view.window == window) return id;
  }
  return -1;
}

int64_t ViewOfGdkWindow(GdkWindow* window) {
  if (window == nullptr) return -1;
  std::lock_guard<std::mutex> lock(views_mutex);
  for (const auto& [id, view] : Views()) {
    if (view.gdk_window == window) return id;
  }
  return -1;
}

template <typename Fn>
Fn Next(const char* name) {
  void* found = dlsym(RTLD_NEXT, name);
  if (found == nullptr) {
    std::fprintf(stderr, "🦝 plugin view: %s not found after the library\n", name);
  }
  return reinterpret_cast<Fn>(found);
}

void Refused(int64_t view, const char* what) {
  std::fprintf(stderr, "🦝 view %lld: a plugin asked to %s its window; it stays hidden, the pane is the window\n",
               static_cast<long long>(view), what);
}

void Recorded(int64_t view, const char* what) {
  std::fprintf(stderr, "🦝 view %lld: a plugin asked its window to %s; recorded, not applied\n",
               static_cast<long long>(view), what);
}

// A toplevel that is mapped after all (a path into GTK the calls below do
// not see): hidden again at once.
gboolean HideAgain(gpointer data) {
  GtkWidget* window = GTK_WIDGET(data);
  ++own_calls;
  gtk_widget_hide(window);
  --own_calls;
  g_object_unref(window);
  return G_SOURCE_REMOVE;
}

void OnMap(GtkWidget* window, gpointer) {
  std::fprintf(stderr, "🦝 view %lld: its window was mapped; hidden again\n",
               static_cast<long long>(ViewOfWindow(window)));
  g_idle_add(HideAgain, g_object_ref(window));
}

void SizeWindow(View& view) {
  using Resize = void (*)(GtkWindow*, gint, gint);
  static const Resize resize = Next<Resize>("gtk_window_resize");
  using GdkResize = void (*)(GdkWindow*, gint, gint);
  static const GdkResize gdk_resize = Next<GdkResize>("gdk_window_resize");
  ++own_calls;
  if (resize != nullptr) resize(GTK_WINDOW(view.window), view.width, view.height);
  GdkWindow* window = gtk_widget_get_window(view.window);
  if (window != nullptr && gdk_resize != nullptr) gdk_resize(window, view.width, view.height);
  --own_calls;
}

// What a GL context on |window| gives, for the log: rive_native and the
// like make theirs so.
void ProbeGl(int64_t id, GdkWindow* window) {
  const gint64 start = g_get_monotonic_time();
  GError* error = nullptr;
  GdkGLContext* context = gdk_window_create_gl_context(window, &error);
  if (context != nullptr && !gdk_gl_context_realize(context, &error)) g_clear_object(&context);
  const double ms = (g_get_monotonic_time() - start) / 1000.0;
  if (context == nullptr) {
    std::fprintf(stderr, "🦝 view %lld: no GL context on its window (%s), %.1f ms\n",
                 static_cast<long long>(id), error != nullptr ? error->message : "?", ms);
    g_clear_error(&error);
    return;
  }
  int major = 0, minor = 0;
  gdk_gl_context_make_current(context);
  gdk_gl_context_get_version(context, &major, &minor);
  gdk_gl_context_clear_current();
  std::fprintf(stderr, "🦝 view %lld: a GL context on its window is %s %d.%d%s, %.1f ms\n",
               static_cast<long long>(id), G_OBJECT_TYPE_NAME(context), major, minor,
               gdk_gl_context_get_use_es(context) ? " ES" : "", ms);
  g_object_unref(context);
}

}  // namespace

extern "C" {

// GTK, with a display: false, said once, without one.
G_MODULE_EXPORT gboolean raccoon_plugin_view_start(void) {
  if (started) return TRUE;
  const gint64 start = g_get_monotonic_time();
  if (!gtk_init_check(nullptr, nullptr)) {
    std::fprintf(stderr, "🦝 plugin view: no display for GTK; plugins get no view\n");
    return FALSE;
  }
  if (!fl_view_raccoon_use_type(RegisterFlView())) {
    std::fprintf(stderr, "🦝 plugin view: FlView was registered before the view; plugins get no view\n");
    return FALSE;
  }
  started = true;
  GdkDisplay* display = gdk_display_get_default();
  std::fprintf(stderr, "🦝 plugin view: GTK on %s (%s), %.1f ms\n", gdk_display_get_name(display),
               G_OBJECT_TYPE_NAME(display), (g_get_monotonic_time() - start) / 1000.0);
  return TRUE;
}

// The FlView of view |id|, made at |width| x |height| logical pixels, or the
// one made before; NULL without GTK.
G_MODULE_EXPORT GObject* raccoon_plugin_view_add(int64_t id, FlEngine* engine, int width,
                                                 int height) {
  if (!started) return nullptr;
  {
    std::lock_guard<std::mutex> lock(views_mutex);
    auto found = Views().find(id);
    if (found != Views().end()) return G_OBJECT(found->second.view);
  }
  const gint64 start = g_get_monotonic_time();
  View made;
  View& view = made;
  view.id = id;
  view.width = width > 0 ? width : 800;
  view.height = height > 0 ? height : 600;
  view.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  // Never in a pager or a task bar, should a compositor show it after all.
  gtk_window_set_skip_taskbar_hint(GTK_WINDOW(view.window), TRUE);
  gtk_window_set_skip_pager_hint(GTK_WINDOW(view.window), TRUE);
  gtk_window_set_title(GTK_WINDOW(view.window), "raccoon plugin view");
  view.view = GTK_WIDGET(g_object_new(RegisterFlView(), "orientation", GTK_ORIENTATION_VERTICAL,
                                      nullptr));
  g_object_set_data(G_OBJECT(view.view), "raccoon-engine", engine);
  g_object_set_data(G_OBJECT(view.view), "raccoon-view-id",
                    GSIZE_TO_POINTER(static_cast<gsize>(id + 1)));
  gtk_container_add(GTK_CONTAINER(view.window), view.view);
  ++own_calls;
  gtk_widget_show(view.view);
  --own_calls;
  gtk_window_set_default_size(GTK_WINDOW(view.window), view.width, view.height);
  g_signal_connect(view.window, "map", G_CALLBACK(OnMap), nullptr);
  gtk_widget_realize(view.window);
  gtk_widget_realize(view.view);
  view.gdk_window = gtk_widget_get_window(view.window);
  {
    std::lock_guard<std::mutex> lock(views_mutex);
    Views()[id] = view;
  }
  SizeWindow(view);
  GdkWindow* window = view.gdk_window;
  std::fprintf(stderr, "🦝 view %lld: plugin view %dx%d, %s, made in %.1f ms\n",
               static_cast<long long>(id), view.width, view.height,
               window != nullptr ? G_OBJECT_TYPE_NAME(window) : "no GdkWindow",
               (g_get_monotonic_time() - start) / 1000.0);
  if (window != nullptr && g_getenv("RACCOON_PLUGIN_VIEW_GL") != nullptr) ProbeGl(id, window);
  return G_OBJECT(view.view);
}

G_MODULE_EXPORT void raccoon_plugin_view_resize(int64_t id, int width, int height) {
  if (width <= 0 || height <= 0) return;
  View view;
  {
    std::lock_guard<std::mutex> lock(views_mutex);
    auto found = Views().find(id);
    if (found == Views().end()) return;
    if (found->second.width == width && found->second.height == height) return;
    found->second.width = width;
    found->second.height = height;
    view = found->second;
  }
  SizeWindow(view);
  if (g_getenv("RACCOON_TRACE") != nullptr) {
    int window_width = 0, window_height = 0;
    gtk_window_get_size(GTK_WINDOW(view.window), &window_width, &window_height);
    std::fprintf(stderr, "🦝 view %lld: plugin view sized %dx%d, GTK says %dx%d\n",
                 static_cast<long long>(id), width, height, window_width, window_height);
  }
}

G_MODULE_EXPORT void raccoon_plugin_view_remove(int64_t id) {
  GtkWidget* window = nullptr;
  {
    std::lock_guard<std::mutex> lock(views_mutex);
    auto found = Views().find(id);
    if (found == Views().end()) return;
    window = found->second.window;
    Views().erase(found);
  }
  gtk_widget_destroy(window);
}

// What a plugin asks of a window, ahead of GTK's. Anything else's window
// goes to GTK as it is.

#define RACCOON_NEXT(name, ...) \
  using Fn = __VA_ARGS__;          \
  static const Fn next = Next<Fn>(#name)

G_MODULE_EXPORT void gtk_widget_show(GtkWidget* widget) {
  RACCOON_NEXT(gtk_widget_show, void (*)(GtkWidget*));
  if (own_calls == 0) {
    if (const int64_t view = ViewOfWindow(widget); view >= 0) return Refused(view, "show");
  }
  next(widget);
}

G_MODULE_EXPORT void gtk_widget_show_all(GtkWidget* widget) {
  RACCOON_NEXT(gtk_widget_show_all, void (*)(GtkWidget*));
  if (const int64_t view = ViewOfWindow(widget); view >= 0) return Refused(view, "show");
  next(widget);
}

G_MODULE_EXPORT void gtk_widget_show_now(GtkWidget* widget) {
  RACCOON_NEXT(gtk_widget_show_now, void (*)(GtkWidget*));
  if (const int64_t view = ViewOfWindow(widget); view >= 0) return Refused(view, "show");
  next(widget);
}

G_MODULE_EXPORT void gtk_widget_set_visible(GtkWidget* widget, gboolean visible) {
  RACCOON_NEXT(gtk_widget_set_visible, void (*)(GtkWidget*, gboolean));
  if (visible && own_calls == 0) {
    if (const int64_t view = ViewOfWindow(widget); view >= 0) return Refused(view, "show");
  }
  next(widget, visible);
}

G_MODULE_EXPORT void gtk_widget_map(GtkWidget* widget) {
  RACCOON_NEXT(gtk_widget_map, void (*)(GtkWidget*));
  if (const int64_t view = ViewOfWindow(widget); view >= 0) return Refused(view, "map");
  next(widget);
}

G_MODULE_EXPORT void gtk_window_present(GtkWindow* window) {
  RACCOON_NEXT(gtk_window_present, void (*)(GtkWindow*));
  if (const int64_t view = ViewOfWindow(window); view >= 0) return Refused(view, "present");
  next(window);
}

G_MODULE_EXPORT void gtk_window_present_with_time(GtkWindow* window, guint32 timestamp) {
  RACCOON_NEXT(gtk_window_present_with_time, void (*)(GtkWindow*, guint32));
  if (const int64_t view = ViewOfWindow(window); view >= 0) return Refused(view, "present");
  next(window, timestamp);
}

G_MODULE_EXPORT void gtk_window_deiconify(GtkWindow* window) {
  RACCOON_NEXT(gtk_window_deiconify, void (*)(GtkWindow*));
  if (const int64_t view = ViewOfWindow(window); view >= 0) Recorded(view, "deiconify");
  next(window);
}

G_MODULE_EXPORT void gtk_window_iconify(GtkWindow* window) {
  RACCOON_NEXT(gtk_window_iconify, void (*)(GtkWindow*));
  if (const int64_t view = ViewOfWindow(window); view >= 0) Recorded(view, "iconify");
  next(window);
}

G_MODULE_EXPORT void gtk_window_resize(GtkWindow* window, gint width, gint height) {
  RACCOON_NEXT(gtk_window_resize, void (*)(GtkWindow*, gint, gint));
  if (own_calls == 0) {
    if (const int64_t view = ViewOfWindow(window); view >= 0) {
      char what[64];
      std::snprintf(what, sizeof(what), "resize to %dx%d", width, height);
      Recorded(view, what);
    }
  }
  next(window, width, height);
}

G_MODULE_EXPORT void gtk_window_move(GtkWindow* window, gint x, gint y) {
  RACCOON_NEXT(gtk_window_move, void (*)(GtkWindow*, gint, gint));
  if (const int64_t view = ViewOfWindow(window); view >= 0) {
    char what[64];
    std::snprintf(what, sizeof(what), "move to %d,%d", x, y);
    Recorded(view, what);
  }
  next(window, x, y);
}

G_MODULE_EXPORT void gtk_window_fullscreen(GtkWindow* window) {
  RACCOON_NEXT(gtk_window_fullscreen, void (*)(GtkWindow*));
  if (const int64_t view = ViewOfWindow(window); view >= 0) Recorded(view, "go full screen");
  next(window);
}

G_MODULE_EXPORT void gtk_window_unfullscreen(GtkWindow* window) {
  RACCOON_NEXT(gtk_window_unfullscreen, void (*)(GtkWindow*));
  if (const int64_t view = ViewOfWindow(window); view >= 0) Recorded(view, "leave full screen");
  next(window);
}

G_MODULE_EXPORT void gtk_window_maximize(GtkWindow* window) {
  RACCOON_NEXT(gtk_window_maximize, void (*)(GtkWindow*));
  if (const int64_t view = ViewOfWindow(window); view >= 0) Recorded(view, "maximize");
  next(window);
}

G_MODULE_EXPORT void gtk_window_unmaximize(GtkWindow* window) {
  RACCOON_NEXT(gtk_window_unmaximize, void (*)(GtkWindow*));
  if (const int64_t view = ViewOfWindow(window); view >= 0) Recorded(view, "unmaximize");
  next(window);
}

G_MODULE_EXPORT void gdk_window_show(GdkWindow* window) {
  RACCOON_NEXT(gdk_window_show, void (*)(GdkWindow*));
  if (const int64_t view = ViewOfGdkWindow(window); view >= 0) return Refused(view, "show");
  next(window);
}

G_MODULE_EXPORT void gdk_window_show_unraised(GdkWindow* window) {
  RACCOON_NEXT(gdk_window_show_unraised, void (*)(GdkWindow*));
  if (const int64_t view = ViewOfGdkWindow(window); view >= 0) return Refused(view, "show");
  next(window);
}

G_MODULE_EXPORT void gdk_window_raise(GdkWindow* window) {
  RACCOON_NEXT(gdk_window_raise, void (*)(GdkWindow*));
  if (const int64_t view = ViewOfGdkWindow(window); view >= 0) return Refused(view, "raise");
  next(window);
}

G_MODULE_EXPORT void gdk_window_focus(GdkWindow* window, guint32 timestamp) {
  RACCOON_NEXT(gdk_window_focus, void (*)(GdkWindow*, guint32));
  if (const int64_t view = ViewOfGdkWindow(window); view >= 0) return Refused(view, "focus");
  next(window, timestamp);
}

G_MODULE_EXPORT void gdk_window_resize(GdkWindow* window, gint width, gint height) {
  RACCOON_NEXT(gdk_window_resize, void (*)(GdkWindow*, gint, gint));
  if (own_calls == 0) {
    if (const int64_t view = ViewOfGdkWindow(window); view >= 0) {
      char what[64];
      std::snprintf(what, sizeof(what), "resize to %dx%d", width, height);
      Recorded(view, what);
    }
  }
  next(window, width, height);
}

G_MODULE_EXPORT void gdk_window_move(GdkWindow* window, gint x, gint y) {
  RACCOON_NEXT(gdk_window_move, void (*)(GdkWindow*, gint, gint));
  if (const int64_t view = ViewOfGdkWindow(window); view >= 0) {
    char what[64];
    std::snprintf(what, sizeof(what), "move to %d,%d", x, y);
    Recorded(view, what);
  }
  next(window, x, y);
}

G_MODULE_EXPORT void gdk_window_move_resize(GdkWindow* window, gint x, gint y, gint width,
                                            gint height) {
  RACCOON_NEXT(gdk_window_move_resize, void (*)(GdkWindow*, gint, gint, gint, gint));
  if (const int64_t view = ViewOfGdkWindow(window); view >= 0) {
    char what[96];
    std::snprintf(what, sizeof(what), "move to %d,%d and resize to %dx%d", x, y, width, height);
    Recorded(view, what);
  }
  next(window, x, y, width, height);
}

G_MODULE_EXPORT void gdk_window_fullscreen(GdkWindow* window) {
  RACCOON_NEXT(gdk_window_fullscreen, void (*)(GdkWindow*));
  if (const int64_t view = ViewOfGdkWindow(window); view >= 0) Recorded(view, "go full screen");
  next(window);
}

}  // extern "C"
