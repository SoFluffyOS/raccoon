#pragma once
// Native plugins, loaded: the project's plugin binaries, built for this
// host, opened into the runner and registered on a registrar of the
// runner's own. On Linux the plugin-facing classes come from
// third_party/flutter_linux, with the engine behind them reached through a
// bridge of five calls. On macOS they come from FlutterMacOS.framework,
// opened from the Flutter SDK before the plugins, and the runner implements
// the messenger, registrar and texture registry protocols over the same
// bridge (third_party/flutter_macos has the headers).
#if RACCOON_HAS_PLUGINS
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#if !defined(__APPLE__)
#include "flutter/shell/platform/linux/fl_engine_private.h"
#include "flutter/shell/platform/linux/public/flutter_linux/fl_plugin_registrar.h"
#endif
#include "flutter_embedder.h"

namespace raccoon {

struct PluginEntry {
  std::string name;
  // The binary to open: a shared library on Linux, a framework's
  // executable on macOS.
  std::string library;
  // Linux: its <name>_plugin_register_with_registrar.
  std::string symbol;
  // macOS: the class the registrant registers, and the Swift module it is
  // in, if any; the class is looked up as module.Class, then as Class.
  std::string plugin_class;
  std::string module;
  // macOS: an FFI plugin's framework, opened for Dart to find its symbols
  // (by name, or in the process) and registered with no one.
  bool ffi = false;
};

// What became of a plugin: the manifest's word on the ones that never got
// as far as a library, the runner's own on the ones it loaded or not.
struct PluginStatus {
  std::string name;
  std::string state;   // loaded, failed, built_nothing, no_host, built_in
  std::string detail;
};

class PluginHost {
 public:
  // What plugins need from the runner.
  struct Bridge {
    // Host to app: a message on a channel, |on_reply| once with the answer
    // (null data when nothing answered).
    std::function<void(const std::string& channel, const uint8_t* data, size_t size,
                       std::function<void(const uint8_t* data, size_t size)> on_reply)>
        send;
    // The answer to a message from the app.
    std::function<void(const FlutterPlatformMessageResponseHandle* handle,
                       const uint8_t* data, size_t size)>
        respond;
    std::function<bool(int64_t texture_id)> register_texture;
    std::function<bool(int64_t texture_id)> mark_texture_frame_available;
    std::function<bool(int64_t texture_id)> unregister_texture;
#if defined(__APPLE__)
    // The id<MTLDevice> plugin textures are drawn with; null without Metal,
    // when textures are not drawn.
    const void* metal_device = nullptr;
#endif
  };

  explicit PluginHost(Bridge bridge);
  ~PluginHost();
  PluginHost(const PluginHost&) = delete;
  PluginHost& operator=(const PluginHost&) = delete;

  // Loads every plugin of a manifest: {"plugins": [{"name", "library",
  // "symbol"}]} on Linux, {"flutter_framework", "plugins": [{"name",
  // "library", "class", "module"} or {"name", "library", "ffi": true}]} on
  // macOS. Each outcome is logged; false with |error| when the manifest
  // itself cannot be read.
  bool LoadManifest(const std::string& path, std::string* error);
  bool Load(const PluginEntry& entry, std::string* error);
  size_t loaded() const { return names_.size(); }
  const std::vector<std::string>& names() const { return names_; }
  // Every plugin the manifest spoke of, with what became of it.
  const std::vector<PluginStatus>& statuses() const { return statuses_; }

  // A message from the app, on the platform thread: true when a plugin
  // took it (it answers through the bridge).
  bool HandleMessage(const std::string& channel, const uint8_t* data, size_t size,
                     const FlutterPlatformMessageResponseHandle* handle);

#if defined(__APPLE__)
  // A frame of a plugin's texture, on the raster thread: its pixel buffer
  // as Metal textures, one plane or two.
  bool PopulateTexture(int64_t texture_id, size_t width, size_t height,
                       FlutterMetalExternalTexture* out);
#else
  // A frame of a plugin's texture, on the raster thread with the GL
  // context current.
  bool PopulateTexture(int64_t texture_id, size_t width, size_t height,
                       FlutterOpenGLTexture* out);
#endif

 private:
  // Opens what every plugin of the manifest needs before any loads: on
  // macOS, |flutter_framework|. False, with why, when it cannot.
  bool Prepare(const std::string& flutter_framework, std::string* error);

  Bridge bridge_;
  std::vector<std::string> names_;
  std::vector<PluginStatus> statuses_;
#if defined(__APPLE__)
  struct Impl;
  std::unique_ptr<Impl> impl_;
#else
  static void SendPlatformMessage(gpointer user_data, const gchar* channel,
                                  const uint8_t* data, size_t size, FlRaccoonReply reply,
                                  gpointer reply_data);
  static gboolean SendPlatformMessageResponse(
      gpointer user_data, const FlutterPlatformMessageResponseHandle* handle,
      const uint8_t* data, size_t size);
  static gboolean RegisterExternalTexture(gpointer user_data, int64_t texture_id);
  static gboolean MarkTextureFrameAvailable(gpointer user_data, int64_t texture_id);
  static gboolean UnregisterExternalTexture(gpointer user_data, int64_t texture_id);

  FlRaccoonBridge c_bridge_{};
  FlEngine* engine_ = nullptr;
  FlBinaryMessenger* messenger_ = nullptr;
  FlTextureRegistrar* textures_ = nullptr;
  FlPluginRegistrar* registrar_ = nullptr;
  std::vector<void*> handles_;
#endif
};

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS
