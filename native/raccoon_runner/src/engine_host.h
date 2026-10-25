#pragma once

#include <atomic>
#include <chrono>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

#include "engine_loader.h"
#include "flutter_embedder.h"
#include "camera_channels.h"
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
  // A PNG or JPEG the camera shows in place of its test pattern; empty
  // takes RACCOON_CAMERA_SOURCE, and without that the pattern.
  std::string camera_source;
  // Views mode: the engine draws through a compositor, and AddView gives
  // the app more views than its own (#182). Off, the engine draws its one
  // view as it always did.
  bool views = false;
};

// One engine: start, metrics, input, shutdown. Rasterizes on the GPU where
// the host has one, in software otherwise.
class EngineHost {
 public:
  using LogCallback =
      std::function<void(const std::string& tag, const std::string& message)>;
  // A platform channel message from the app. |handle| is null when the app
  // expects no reply; otherwise Respond must be called with it exactly once.
  // The window, shared preferences and camera channels never get here: the
  // host answers them itself (see window_channels.h,
  // user_defaults_channels.h, camera_channels.h).
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
  // "🦝 nothing answered CHANNEL (WHY); the app sees no
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

  // Views mode. A view of the app's beyond its own, numbered from 1: the
  // engine takes it at its first Resize, and RemoveView lets it go. 0 when
  // the host is not in views mode.
  FlutterViewId AddView();
  void RemoveView(FlutterViewId view);
  bool views() const { return views_mode_; }

  // The calls below name a view: 0 is the app's own, which every host has.
  // A view not (or no longer) there is let be.
  void Resize(FlutterViewId view, size_t width, size_t height, double pixel_ratio);
  // Draws the app again at the size it has: a client that arrives at an
  // idle app gets a frame of its own, whatever the one before took them
  // as (#138). Nothing before the first Resize.
  void Redraw(FlutterViewId view);
  void SendPointer(FlutterViewId view, const FlutterPointerEvent& event);
  // Tells the app |view| has the focus now: the keyboard's keys go there.
  void FocusView(FlutterViewId view);
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
  // Sends the camera's events and stream frames that are due. From the loop
  // thread, every iteration.
  void ServiceCamera();
  // Milliseconds until ServiceCamera has something to do, or -1.
  int MillisUntilCamera() const;

  // The VM service URI once the engine announced it, else empty.
  std::string vm_service_uri() const;
  // Which renderer rasterizes, for the log: "software", or "gl (...)".
  const std::string& renderer() const { return renderer_; }

  // GPU buffers: the engine draws into a ring of exported buffers and frames
  // are buffer indices (see GpuRenderer). False, with why, without a GPU
  // renderer that exports.
  bool EnableGpuBuffers(FlutterViewId view, size_t count, std::string* error);
  void DisableGpuBuffers(FlutterViewId view);
  bool GpuBufferSetNow(FlutterViewId view, GpuBufferSet* out) const;
  // |fence_fd|, when not -1, is signalled once the client's last use of the
  // buffer is done; owned from here.
  void ReleaseGpuBuffer(FlutterViewId view, uint32_t generation, int index,
                        int fence_fd = -1);
  // Every buffer is the runner's again: the client holding them is gone.
  void ReleaseAllGpuBuffers(FlutterViewId view);
  // A frame went by readback that a client taking the ring never saw, and
  // a buffer is free now: asks for another. From the loop, every turn.
  void RedrawIfMissed();
#if RACCOON_HAS_METAL
  // Whether the host takes the ring's surfaces by Mach port, the ring then
  // not global; on a change a frame is asked for, so the new ring comes at
  // once. False without the Metal renderer.
  bool ShareGpuBuffersByPort(FlutterViewId view, bool by_port);
  bool can_share_gpu_buffers_by_port() const { return metal_ != nullptr; }
  // Send rights to ring |generation|'s surfaces, for the caller to pass on.
  bool GpuBufferPorts(FlutterViewId view, uint32_t generation,
                      std::vector<uint32_t>* ports) const;
#endif

  // Takes what views mode has to do on the loop: metrics for a view the
  // engine took since. From the loop thread, every iteration.
  void ServiceViews();

  // View 0's frames.
  SoftwareFrame& frame() { return *frame(0); }
  // |view|'s frames; null for a view not there.
  SoftwareFrame* frame(FlutterViewId view);
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
  // What Resize scaled the frame by to fit (#117), so pointer events from
  // the host scale with it (#130); 1 almost always. Loop thread.
  double input_scale_ = 1.0;
  // The metrics Resize last sent, for Redraw. Loop thread.
  FlutterWindowMetricsEvent metrics_{};

  // Views mode (#182). Each view is drawn into a target of its own: a
  // sibling of the renderer, sharing its device or context, with a ring and
  // a readback of its own, or a buffer for the software renderer. View 0's
  // is the renderer itself, and frame_.
  struct View {
    explicit View(FlutterViewId id) : id(id) {}
    const FlutterViewId id;
    SoftwareFrame frame;
    std::unique_ptr<GpuRenderer> gpu;
#if RACCOON_HAS_GL
    GlRenderer* gl = nullptr;
#endif
#if RACCOON_HAS_METAL
    MetalRenderer* metal = nullptr;
#endif
    // The software renderer's backing store, kept from frame to frame.
    std::vector<uint8_t> pixels;
    bool removing = false;
    // Loop thread: the metrics last asked for, and the scale they fit by.
    FlutterWindowMetricsEvent metrics{};
    double input_scale = 1.0;
    // The engine was asked to take it, and has; metrics that came between
    // are sent once it has.
    bool asked = false;
    std::atomic<bool> added{false};
    std::atomic<bool> metrics_owed{false};
  };
  // What a view is drawn into, view 0's or another's.
  struct Target {
    SoftwareFrame* frame = nullptr;
    GpuRenderer* gpu = nullptr;
#if RACCOON_HAS_GL
    GlRenderer* gl = nullptr;
#endif
#if RACCOON_HAS_METAL
    MetalRenderer* metal = nullptr;
#endif
    std::vector<uint8_t>* pixels = nullptr;
    // Holds another view's target while it is used.
    std::shared_ptr<View> view;
  };
  // False for a view not there. Any thread.
  bool TargetOf(FlutterViewId view, Target* out);
  std::shared_ptr<View> ViewOf(FlutterViewId view) const;
  // Makes a target for a view beside the renderer's; false, with why, when
  // this renderer cannot.
  bool MakeTarget(View& view, std::string* error);
  // Whether every view's ring has a buffer for the next frame.
  bool HasFreeBuffers() const;
  // |view|'s GPU target, null on the software renderer or for a view not
  // there. Loop thread.
  GpuRenderer* GpuOf(FlutterViewId view) const;
  // Calls |each| with every view's GPU target.
  void ForEachGpu(const std::function<void(GpuRenderer&)>& each) const;
  // Lets go the targets of views removed; |gl_current| says the GL context
  // is current, as on the raster thread, which GL targets wait for.
  void DropRetired(bool gl_current);
  static bool CreateBackingStore(const FlutterBackingStoreConfig* config,
                                 FlutterBackingStore* out, void* user_data);
  static bool CollectBackingStore(const FlutterBackingStore* store, void* user_data);
  static bool PresentView(const FlutterPresentViewInfo* info);
  static void OnViewAdded(const FlutterAddViewResult* result);
  static void OnViewRemoved(const FlutterRemoveViewResult* result);
  bool views_mode_ = false;
  FlutterCompositor compositor_{};
  // The views beyond view 0, and the ones removed, kept until the raster
  // thread lets their targets go (a GL target needs the context current).
  mutable std::mutex views_mutex_;
  std::map<FlutterViewId, std::shared_ptr<View>> views_;
  std::vector<std::shared_ptr<View>> retired_;
  FlutterViewId next_view_ = 1;
  // Which view has the focus, as the app was last told.
  FlutterViewId focused_ = 0;
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
  // The modifier keys down, a bit each by its logical key's offset from
  // Control Left: Control, Shift, Alt and Meta, left then right.
  uint8_t modifiers_ = 0;
  UserDefaultsChannels user_defaults_;
  CameraChannels camera_;
  FLUTTER_API_SYMBOL(FlutterEngine) engine_ = nullptr;
  LogCallback on_log_;
  PlatformMessageCallback on_platform_message_;
  // What RespondNoPlugin has logged, why and channel, so each is said once.
  std::unordered_set<std::string> unanswered_;
#if RACCOON_HAS_PLUGINS
  std::unique_ptr<PluginHost> plugins_;
  // A plugin's call into the engine comes from any thread. Each is counted
  // and made only while the engine isn't stopping; Shutdown says it is,
  // then waits for the calls under way (#129).
  template <typename Call>
  bool PluginCall(Call call);
  std::atomic<int> plugin_calls_{0};
  std::atomic<bool> stopping_{false};
#endif
  // The engine's external textures, on the raster thread: the camera's
  // previews, then the plugins' textures.
#if RACCOON_HAS_METAL
  static bool MetalExternalTexture(void* user_data, int64_t texture_id, size_t width,
                                   size_t height, FlutterMetalExternalTexture* out);
#endif
#if RACCOON_HAS_GL
  static bool GlExternalTexture(void* user_data, int64_t texture_id, size_t width,
                                size_t height, FlutterOpenGLTexture* out);
#endif
  // Hands the camera the engine's external textures, when the renderer
  // draws them.
  void GiveCameraTextures();
  std::function<void()> on_wake_;
  static void OnVsync(void* user_data, intptr_t baton);
  mutable std::mutex vsync_mutex_;
  bool vsync_pending_ = false;
  intptr_t vsync_baton_ = 0;
  // When the engine asked, and when the next frame is due (0: now).
  uint64_t vsync_asked_nanos_ = 0;
  uint64_t next_frame_nanos_ = 0;
  // A frame went by readback for want of a ring buffer; a client drawing
  // the ring does not show it, so the next release asks for another.
  bool gpu_frame_owed_ = false;
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
