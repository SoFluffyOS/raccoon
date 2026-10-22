#pragma once
// What the runner gives the vendored embedding classes in place of an
// FlEngine of their own: the few engine calls the messenger and the texture
// registrar make, as function pointers over the raw embedder API.
#include <glib.h>
#include <stdint.h>

#include "flutter/shell/platform/embedder/embedder.h"

G_BEGIN_DECLS

// Called once with the reply to a platform message, on the platform thread;
// |data| is NULL with |size| 0 when nothing answered.
typedef void (*FlRaccoonReply)(const uint8_t* data, size_t size, gpointer reply_data);

typedef struct {
  // Host to app: sends |data| on |channel| and later calls |reply|.
  void (*send_platform_message)(gpointer user_data, const gchar* channel, const uint8_t* data,
                                size_t size, FlRaccoonReply reply, gpointer reply_data);
  // Answers a message the app sent; |handle| came with the message.
  gboolean (*send_platform_message_response)(gpointer user_data,
                                             const FlutterPlatformMessageResponseHandle* handle,
                                             const uint8_t* data, size_t size);
  gboolean (*register_external_texture)(gpointer user_data, int64_t texture_id);
  gboolean (*mark_texture_frame_available)(gpointer user_data, int64_t texture_id);
  gboolean (*unregister_external_texture)(gpointer user_data, int64_t texture_id);
} FlRaccoonBridge;

G_END_DECLS
