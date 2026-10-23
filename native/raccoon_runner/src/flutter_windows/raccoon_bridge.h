#pragma once
// Between the runner and its flutter_windows.dll, the C API Windows plugins
// call (third_party/flutter_windows). The runner opens the DLL before any
// plugin, attaches the engine behind it through this bridge, gets a
// registrar per plugin, and hands it the app's messages. Plain C on both
// sides: each has a C runtime of its own, so nothing allocated on one side
// is freed on the other.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// The embedder's header defines FLUTTER_EXPORT too, differently; the runner
// includes both.
#pragma push_macro("FLUTTER_EXPORT")
#undef FLUTTER_EXPORT
#include "flutter_messenger.h"
#include "flutter_plugin_registrar.h"
#pragma pop_macro("FLUTTER_EXPORT")

#if defined(__cplusplus)
extern "C" {
#endif

typedef struct {
  size_t struct_size;
  void* user_data;
  // Host to app on |channel|; |reply| once with the answer (null data when
  // nothing answered), unless it is null. False when the engine is gone.
  bool (*send)(void* user_data, const char* channel, const uint8_t* data, size_t size,
               FlutterDesktopBinaryReply reply, void* reply_user_data);
  // The answer to a message from the app.
  void (*respond)(void* user_data, const FlutterDesktopMessageResponseHandle* handle,
                  const uint8_t* data, size_t size);
} RaccoonWindowsBridge;

// Attaches the engine and makes the plugins' view, on the platform thread.
// False when the view's window cannot be made.
typedef bool (*RaccoonWindowsAttachFn)(const RaccoonWindowsBridge* bridge);

// A registrar for one plugin, on the attached engine.
typedef FlutterDesktopPluginRegistrarRef (*RaccoonWindowsRegistrarFn)(const char* plugin);

// A message from the app, on the platform thread: true when a plugin has a
// callback on its channel and took it (it answers through the bridge).
typedef bool (*RaccoonWindowsHandleMessageFn)(const char* channel, const uint8_t* data,
                                              size_t size,
                                              const FlutterDesktopMessageResponseHandle* handle);

// The engine is going: the registrars' destruction handlers run, and the
// messenger says it is no longer available.
typedef void (*RaccoonWindowsDetachFn)(void);

#if defined(__cplusplus)
}  // extern "C"
#endif
