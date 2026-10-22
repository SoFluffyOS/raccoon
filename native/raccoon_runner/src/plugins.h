#pragma once
// Native plugins, loaded: the project's plugin binaries, built for this
// host, opened into the runner and registered on a registrar of the
// runner's own. The plugin-facing classes come from third_party/flutter_linux;
// the engine behind them is this runner, through a bridge of five calls.
#if RACCOON_HAS_PLUGINS
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "flutter/shell/platform/linux/fl_engine_private.h"
#include "flutter/shell/platform/linux/public/flutter_linux/fl_plugin_registrar.h"
#include "flutter_embedder.h"

namespace raccoon {

struct PluginEntry {
  std::string name;
  std::string library;  // the shared library's path
  std::string symbol;   // its <name>_plugin_register_with_registrar
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
  };

  explicit PluginHost(Bridge bridge);
  ~PluginHost();
  PluginHost(const PluginHost&) = delete;
  PluginHost& operator=(const PluginHost&) = delete;

  // Loads every plugin of a manifest: {"plugins": [{"name", "library",
  // "symbol"}]}. Each outcome is logged; false with |error| when the
  // manifest itself cannot be read.
  bool LoadManifest(const std::string& path, std::string* error);
  bool Load(const PluginEntry& entry, std::string* error);
  size_t loaded() const { return names_.size(); }
  const std::vector<std::string>& names() const { return names_; }

  // A message from the app, on the platform thread: true when a plugin
  // took it (it answers through the bridge).
  bool HandleMessage(const std::string& channel, const uint8_t* data, size_t size,
                     const FlutterPlatformMessageResponseHandle* handle);

  // A frame of a plugin's texture, on the raster thread with the GL
  // context current.
  bool PopulateTexture(int64_t texture_id, size_t width, size_t height,
                       FlutterOpenGLTexture* out);

 private:
  static void SendPlatformMessage(gpointer user_data, const gchar* channel,
                                  const uint8_t* data, size_t size, FlRaccoonReply reply,
                                  gpointer reply_data);
  static gboolean SendPlatformMessageResponse(
      gpointer user_data, const FlutterPlatformMessageResponseHandle* handle,
      const uint8_t* data, size_t size);
  static gboolean RegisterExternalTexture(gpointer user_data, int64_t texture_id);
  static gboolean MarkTextureFrameAvailable(gpointer user_data, int64_t texture_id);
  static gboolean UnregisterExternalTexture(gpointer user_data, int64_t texture_id);

  Bridge bridge_;
  FlRaccoonBridge c_bridge_{};
  FlEngine* engine_ = nullptr;
  FlBinaryMessenger* messenger_ = nullptr;
  FlTextureRegistrar* textures_ = nullptr;
  FlPluginRegistrar* registrar_ = nullptr;
  std::vector<void*> handles_;
  std::vector<std::string> names_;
};

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS
