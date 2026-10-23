#pragma once

#include <chrono>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

#include "engine_loader.h"
#include "flutter_embedder.h"
#include "gpu_renderer.h"
#if RACCOON_HAS_PLUGINS
#include "plugins.h"
#endif
#if RACCOON_HAS_GL
#include "gl_renderer.h"
#endif
#if RACCOON_HAS_VULKAN
#include "vulkan_renderer.h"
#endif
#if RACCOON_HAS_METAL
#include "metal_renderer.h"
#endif
#include "platform_task_runner.h"
#include "software_frame.h"
#include "text_input.h"
#include "user_defaults_channels.h"
#include "window_channels.h"

namespace raccoon {

struct EngineOptions {
  std::string engine_dir;
  std::string assets;
  std::string icu;
  size_t width = 800;
  size_t height = 600;
  double pixel_ratio = 1.0;
  // Where the app's own data persists across runs (its shared preferences);
  // empty keeps it in memory.
  std::string data_dir;
  // Engine switches appended to the command line, e.g. --vm-service-port=N.
  std::vector<std::string> extra_args;
  // "auto" rasterizes on the GPU when this host offers one (EGL on Linux,
  // Metal on macOS) and falls back to the software renderer; "gl" or
  // "metal" insists; "software" never tries.
  std::string renderer = "auto";
};

// One engine: start, metrics, input, shutdown. Rasterizes on the GPU where
// the host has one, in software otherwise.
class EngineHost {
 public:
  using LogCallback =
      std::function<void(const std::string& tag, const std::string& message)>;
  // A platform channel message from the app. |handle| is null when the app
  // expects no reply; otherwise Respond must be called with it exactly once.
  // The window and shared preferences channels never get here: the host
  // answers them itself (see window_channels.h, user_defaults_channels.h).
  using PlatformMessageCallback = std::function<void(
      const std::string& channel, const uint8_t* data, size_t size,
      const FlutterPlatformMessageResponseHandle* handle)>;

  // |on_wake| is called from any thread when the owner's loop has work: a
  // task was posted or a frame was presented.
  bool Start(const EngineOptions& options, LogCallback on_log,
             std::function<void()> on_wake, std::string* error);

  // Messages arrive on the owner's thread (the platform task runner).
  void SetPlatformMessageCallback(PlatformMessageCallback callback) {
    on_platform_message_ = std::move(callback);
  }

  // Answers a platform message; |data| may be null for "not handled".
  void Respond(const FlutterPlatformMessageResponseHandle* handle,
               const uint8_t* data, size_t size);
  // Answers with nothing, which the app sees as no plugin
  // (MissingPluginException, or Pigeon's channel-error), and says so on
  // stderr the first time |channel| goes unanswered for |why|:
  // "raccoon_runner: nothing answered CHANNEL (WHY); the app sees no
  // plugin". Hosts and the tool's output name the channel from that line.
  // A message that expects no reply (|handle| null) is let go quietly, and
  // so are the engine's own flutter/ channels.
  void RespondNoPlugin(const std::string& channel,
                       const FlutterPlatformMessageResponseHandle* handle,
                       const char* why);

  // Loads the native plugins of a manifest (see plugins.h); their channels
  // are answered before a client sees them. After Start. False, with why,
  // when this runner cannot or the manifest cannot be read.
  bool LoadPlugins(const std::string& manifest, std::string* error);
  size_t plugins_loaded() const;
#if RACCOON_HAS_PLUGINS
  const std::vector<PluginStatus>& plugin_statuses() const;
#endif

  void Resize(size_t width, size_t height, double pixel_ratio);
  void SendPointer(const FlutterPointerEvent& event);
  // Sends the key to the framework, then the legacy flutter/keyevent message
  // the framework waits for before dispatching it. A key down it does not
  // handle goes to the text field, when one is active.
  void SendKey(const FlutterKeyEvent& event);
  // Sends a message to the framework; |on_reply| gets its answer, if asked.
  void SendPlatformMessage(
      const std::string& channel, const uint8_t* data, size_t size,
      std::function<void(const uint8_t* data, size_t size)> on_reply = nullptr);
  void Shutdown();

  // Microseconds on the engine's clock.
  uint64_t NowMicros() const { return loader_.procs().GetCurrentTime() / 1000; }
  // The engine asks for each frame; this answers when the frame is due, at
  // 60 Hz, and with a GPU ring only once a buffer is free, up to a cap.
  // From the loop thread, every iteration.
  void ServiceVsync();
  // Milliseconds until ServiceVsync has something to do: -1 when the engine
  // has not asked, 0 when it is due.
  int MillisUntilVsync() const;

  // The VM service URI once the engine announced it, else empty.
  std::string vm_service_uri() const;
  // Which renderer rasterizes, for the log: "software", or "gl (...)".
  const std::string& renderer() const { return renderer_; }

  // GPU buffers: the engine draws into a ring of exported buffers and frames
  // are buffer indices (see GpuRenderer). False, with why, without a GPU
  // renderer that exports.
  bool EnableGpuBuffers(size_t count, std::string* error);
  void DisableGpuBuffers();
  bool GpuBufferSetNow(GpuBufferSet* out) const;
  // |fence_fd|, when not -1, is signalled once the client's last use of the
  // buffer is done; owned from here.
  void ReleaseGpuBuffer(uint32_t generation, int index, int fence_fd = -1);
  // Every buffer is the runner's again: the client holding them is gone.
  void ReleaseAllGpuBuffers();
#if RACCOON_HAS_METAL
  // The host takes the ring's surfaces by Mach port: the next ring is not
  // global, and a frame is asked for so it comes at once. False without
  // the Metal renderer.
  bool ShareGpuBuffersByPort();
  // Send rights to ring |generation|'s surfaces, for the caller to pass on.
  bool GpuBufferPorts(uint32_t generation, std::vector<uint32_t>* ports) const;
#endif

  SoftwareFrame& frame() { return frame_; }
  TextInput& text_input() { return text_input_; }
  PlatformTaskRunner& platform() { return *platform_; }
  std::chrono::steady_clock::time_point started() const { return started_; }

 private:
  // The host's locales and settings, for the app (see host_settings.h).
  void SendHostSettings();
  static bool OnPresent(void* user_data, const void* allocation,
                        size_t row_bytes, size_t height);
  // Picks the renderer |wanted| names and fills |renderer| for the engine.
  bool ConfigureRenderer(const std::string& wanted,
                         FlutterRendererConfig* renderer, std::string* error);
  // The GPU renderer this host built, null on the software renderer; the
  // typed pointer beside it serves the engine's callbacks.
  std::unique_ptr<GpuRenderer> gpu_;
#if RACCOON_HAS_GL
  static bool GlMakeCurrent(void* user_data);
  static bool GlClearCurrent(void* user_data);
  static bool GlMakeResourceCurrent(void* user_data);
  static uint32_t GlFbo(void* user_data, const FlutterFrameInfo* info);
  static bool GlPresent(void* user_data, const FlutterPresentInfo* info);
  static void* GlProc(void* user_data, const char* name);
  GlRenderer* gl_ = nullptr;
#endif
#if RACCOON_HAS_METAL
  static FlutterMetalTexture MetalNextDrawable(void* user_data,
                                               const FlutterFrameInfo* info);
  static bool MetalPresent(void* user_data, const FlutterMetalTexture* texture);
  MetalRenderer* metal_ = nullptr;
#endif
#if RACCOON_HAS_VULKAN
  static void* VulkanProc(void* user_data, FlutterVulkanInstanceHandle instance,
                          const char* name);
  static FlutterVulkanImage VulkanNextImage(void* user_data, const FlutterFrameInfo* info);
  static bool VulkanPresent(void* user_data, const FlutterVulkanImage* image);
  VulkanRenderer* vulkan_ = nullptr;
#endif
  std::string renderer_ = "software";
  static void OnLog(const char* tag, const char* message, void* user_data);
  static void OnPlatformMessage(const FlutterPlatformMessage* message,
                                void* user_data);

  EngineLoader loader_;
  std::unique_ptr<PlatformTaskRunner> platform_;
  SoftwareFrame frame_;
  void TrackModifiers(const FlutterKeyEvent& event);
  std::string RawKeyMessage(const FlutterKeyEvent& event,
                            const std::string& character) const;
  WindowChannels windows_;
  TextInput text_input_;
  bool shift_ = false;
  bool control_ = false;
  bool alt_ = false;
  bool meta_ = false;
  UserDefaultsChannels user_defaults_;
  FLUTTER_API_SYMBOL(FlutterEngine) engine_ = nullptr;
  LogCallback on_log_;
  PlatformMessageCallback on_platform_message_;
  // What RespondNoPlugin has logged, why and channel, so each is said once.
  std::unordered_set<std::string> unanswered_;
#if RACCOON_HAS_PLUGINS
  std::unique_ptr<PluginHost> plugins_;
#if RACCOON_HAS_METAL
  static bool MetalExternalTexture(void* user_data, int64_t texture_id, size_t width,
                                   size_t height, FlutterMetalExternalTexture* out);
#else
  static bool GlExternalTexture(void* user_data, int64_t texture_id, size_t width,
                                size_t height, FlutterOpenGLTexture* out);
#endif
#endif
  std::function<void()> on_wake_;
  static void OnVsync(void* user_data, intptr_t baton);
  mutable std::mutex vsync_mutex_;
  bool vsync_pending_ = false;
  intptr_t vsync_baton_ = 0;
  // When the engine asked, and when the next frame is due (0: now).
  uint64_t vsync_asked_nanos_ = 0;
  uint64_t next_frame_nanos_ = 0;
  std::chrono::steady_clock::time_point started_;
  std::string assets_;
  std::string icu_;
  std::vector<std::string> command_line_;
  std::vector<const char*> argv_;
  FlutterCustomTaskRunners runners_{};
  mutable std::mutex mutex_;
  std::string vm_service_uri_;
};

}  // namespace raccoon
