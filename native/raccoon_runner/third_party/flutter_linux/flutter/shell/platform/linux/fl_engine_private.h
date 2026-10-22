#pragma once
// Raccoon's stand-in for the GTK embedding's private engine header. The
// vendored messenger and texture registrar reach their engine through these
// calls; here an FlEngine is a thin object over the runner's bridge, not the
// embedding's own engine. Kept to the declarations those sources use.
#include <gio/gio.h>
#include <glib-object.h>

#include "flutter/shell/platform/embedder/embedder.h"
#include "flutter/shell/platform/linux/public/flutter_linux/fl_engine.h"
#include "raccoon/fl_raccoon_bridge.h"

G_BEGIN_DECLS

typedef enum {
  FL_ENGINE_ERROR_FAILED,
} FlEngineError;

GQuark fl_engine_error_quark(void) G_GNUC_CONST;
#define FL_ENGINE_ERROR fl_engine_error_quark()

typedef gboolean (*FlEnginePlatformMessageHandler)(
    FlEngine* engine,
    const gchar* channel,
    GBytes* message,
    const FlutterPlatformMessageResponseHandle* response_handle,
    gpointer user_data);

void fl_engine_set_platform_message_handler(FlEngine* engine,
                                            FlEnginePlatformMessageHandler handler,
                                            gpointer user_data,
                                            GDestroyNotify destroy_notify);

gboolean fl_engine_send_platform_message_response(
    FlEngine* engine,
    const FlutterPlatformMessageResponseHandle* handle,
    GBytes* response,
    GError** error);

void fl_engine_send_platform_message(FlEngine* engine,
                                     const gchar* channel,
                                     GBytes* message,
                                     GCancellable* cancellable,
                                     GAsyncReadyCallback callback,
                                     gpointer user_data);

GBytes* fl_engine_send_platform_message_finish(FlEngine* engine,
                                               GAsyncResult* result,
                                               GError** error);

gboolean fl_engine_register_external_texture(FlEngine* engine, int64_t texture_id);
gboolean fl_engine_mark_texture_frame_available(FlEngine* engine, int64_t texture_id);
gboolean fl_engine_unregister_external_texture(FlEngine* engine, int64_t texture_id);

// Raccoon's additions.

// An engine over |bridge|, which must outlive it.
FlEngine* fl_engine_new_raccoon(const FlRaccoonBridge* bridge, gpointer user_data);

// A message the app sent: TRUE when a handler took it (and will answer
// through the bridge), FALSE when nothing listens on |channel|.
gboolean fl_engine_raccoon_handle_platform_message(
    FlEngine* engine,
    const gchar* channel,
    const uint8_t* data,
    size_t size,
    const FlutterPlatformMessageResponseHandle* response_handle);

G_END_DECLS
