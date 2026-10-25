// An FlEngine that is the runner: the vendored messenger and texture
// registrar call it, it calls the bridge.
#include "flutter/shell/platform/linux/fl_engine_private.h"

#include "flutter/shell/platform/linux/fl_binary_messenger_private.h"
#include "flutter/shell/platform/linux/fl_texture_registrar_private.h"

struct _FlEngine {
  GObject parent_instance;
  // Null once detached; read under |bridge_lock| by every call into it,
  // which plugins make from any thread.
  const FlRaccoonBridge* bridge;
  GRWLock bridge_lock;
  gpointer user_data;
  FlEnginePlatformMessageHandler handler;
  gpointer handler_data;
  GDestroyNotify handler_destroy;
  FlBinaryMessenger* messenger;
  FlTextureRegistrar* texture_registrar;
};

G_DEFINE_QUARK(fl_engine_error_quark, fl_engine_error)

G_DEFINE_TYPE(FlEngine, fl_engine, G_TYPE_OBJECT)

static void fl_engine_dispose(GObject* object) {
  FlEngine* self = FL_ENGINE(object);
  if (self->handler_destroy != nullptr) {
    self->handler_destroy(self->handler_data);
  }
  self->handler = nullptr;
  self->handler_data = nullptr;
  self->handler_destroy = nullptr;
  g_clear_object(&self->messenger);
  g_clear_object(&self->texture_registrar);
  G_OBJECT_CLASS(fl_engine_parent_class)->dispose(object);
}

static void fl_engine_finalize(GObject* object) {
  g_rw_lock_clear(&FL_ENGINE(object)->bridge_lock);
  G_OBJECT_CLASS(fl_engine_parent_class)->finalize(object);
}

static void fl_engine_class_init(FlEngineClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = fl_engine_dispose;
  G_OBJECT_CLASS(klass)->finalize = fl_engine_finalize;
}

static void fl_engine_init(FlEngine* self) { g_rw_lock_init(&self->bridge_lock); }

// The bridge, held until unlock_bridge; null once the runner detached it.
static const FlRaccoonBridge* lock_bridge(FlEngine* self) {
  g_rw_lock_reader_lock(&self->bridge_lock);
  return self->bridge;
}

static void unlock_bridge(FlEngine* self) { g_rw_lock_reader_unlock(&self->bridge_lock); }

FlEngine* fl_engine_new_raccoon(const FlRaccoonBridge* bridge, gpointer user_data) {
  FlEngine* self = FL_ENGINE(g_object_new(fl_engine_get_type(), nullptr));
  self->bridge = bridge;
  self->user_data = user_data;
  return self;
}

void fl_engine_raccoon_detach(FlEngine* self) {
  g_return_if_fail(FL_IS_ENGINE(self));
  g_rw_lock_writer_lock(&self->bridge_lock);
  self->bridge = nullptr;
  g_rw_lock_writer_unlock(&self->bridge_lock);
}

void fl_engine_set_platform_message_handler(FlEngine* self,
                                            FlEnginePlatformMessageHandler handler,
                                            gpointer user_data,
                                            GDestroyNotify destroy_notify) {
  g_return_if_fail(FL_IS_ENGINE(self));
  if (self->handler_destroy != nullptr) self->handler_destroy(self->handler_data);
  self->handler = handler;
  self->handler_data = user_data;
  self->handler_destroy = destroy_notify;
}

gboolean fl_engine_raccoon_handle_platform_message(
    FlEngine* self, const gchar* channel, const uint8_t* data, size_t size,
    const FlutterPlatformMessageResponseHandle* response_handle) {
  g_return_val_if_fail(FL_IS_ENGINE(self), FALSE);
  if (self->handler == nullptr) return FALSE;
  g_autoptr(GBytes) message = g_bytes_new(data, size);
  return self->handler(self, channel, message, response_handle, self->handler_data);
}

gboolean fl_engine_send_platform_message_response(
    FlEngine* self, const FlutterPlatformMessageResponseHandle* handle,
    GBytes* response, GError** error) {
  g_return_val_if_fail(FL_IS_ENGINE(self), FALSE);
  gsize size = 0;
  const uint8_t* data = response == nullptr
                            ? nullptr
                            : static_cast<const uint8_t*>(g_bytes_get_data(response, &size));
  const FlRaccoonBridge* bridge = lock_bridge(self);
  const gboolean sent =
      bridge != nullptr && bridge->send_platform_message_response(self->user_data, handle, data, size);
  unlock_bridge(self);
  if (!sent) {
    g_set_error(error, FL_ENGINE_ERROR, FL_ENGINE_ERROR_FAILED,
                "Failed to send platform message response");
    return FALSE;
  }
  return TRUE;
}

static void on_reply(const uint8_t* data, size_t size, gpointer reply_data) {
  GTask* task = G_TASK(reply_data);
  g_task_return_pointer(task, g_bytes_new(data, size),
                        reinterpret_cast<GDestroyNotify>(g_bytes_unref));
  g_object_unref(task);
}

void fl_engine_send_platform_message(FlEngine* self, const gchar* channel,
                                     GBytes* message, GCancellable* cancellable,
                                     GAsyncReadyCallback callback, gpointer user_data) {
  g_return_if_fail(FL_IS_ENGINE(self));
  // Without a callback nobody waits for the answer: the app is asked for
  // none, as an event channel's events want.
  GTask* task = callback == nullptr ? nullptr : g_task_new(self, cancellable, callback, user_data);
  gsize size = 0;
  const uint8_t* data = message == nullptr
                            ? nullptr
                            : static_cast<const uint8_t*>(g_bytes_get_data(message, &size));
  const FlRaccoonBridge* bridge = lock_bridge(self);
  if (bridge != nullptr) {
    bridge->send_platform_message(self->user_data, channel, data, size,
                                  task == nullptr ? nullptr : on_reply, task);
  }
  unlock_bridge(self);
  if (bridge == nullptr && task != nullptr) {
    g_task_return_new_error(task, FL_ENGINE_ERROR, FL_ENGINE_ERROR_FAILED, "The engine is gone");
    g_object_unref(task);
  }
}

GBytes* fl_engine_send_platform_message_finish(FlEngine* self, GAsyncResult* result,
                                               GError** error) {
  g_return_val_if_fail(FL_IS_ENGINE(self), nullptr);
  g_return_val_if_fail(g_task_is_valid(result, self), nullptr);
  return static_cast<GBytes*>(g_task_propagate_pointer(G_TASK(result), error));
}

gboolean fl_engine_register_external_texture(FlEngine* self, int64_t texture_id) {
  g_return_val_if_fail(FL_IS_ENGINE(self), FALSE);
  const FlRaccoonBridge* bridge = lock_bridge(self);
  const gboolean ok =
      bridge != nullptr && bridge->register_external_texture(self->user_data, texture_id);
  unlock_bridge(self);
  return ok;
}

gboolean fl_engine_mark_texture_frame_available(FlEngine* self, int64_t texture_id) {
  g_return_val_if_fail(FL_IS_ENGINE(self), FALSE);
  const FlRaccoonBridge* bridge = lock_bridge(self);
  const gboolean ok =
      bridge != nullptr && bridge->mark_texture_frame_available(self->user_data, texture_id);
  unlock_bridge(self);
  return ok;
}

gboolean fl_engine_unregister_external_texture(FlEngine* self, int64_t texture_id) {
  g_return_val_if_fail(FL_IS_ENGINE(self), FALSE);
  const FlRaccoonBridge* bridge = lock_bridge(self);
  const gboolean ok =
      bridge != nullptr && bridge->unregister_external_texture(self->user_data, texture_id);
  unlock_bridge(self);
  return ok;
}

// The two public accessors a plugin might call on an engine. The runner
// takes its messenger and registrar from them too: a second messenger would
// take over the engine's messages from the first.
G_MODULE_EXPORT FlBinaryMessenger* fl_engine_get_binary_messenger(FlEngine* self) {
  g_return_val_if_fail(FL_IS_ENGINE(self), nullptr);
  if (self->messenger == nullptr) self->messenger = fl_binary_messenger_new(self);
  return self->messenger;
}

G_MODULE_EXPORT FlTextureRegistrar* fl_engine_get_texture_registrar(FlEngine* self) {
  g_return_val_if_fail(FL_IS_ENGINE(self), nullptr);
  if (self->texture_registrar == nullptr) {
    self->texture_registrar = fl_texture_registrar_new(self);
  }
  return self->texture_registrar;
}
