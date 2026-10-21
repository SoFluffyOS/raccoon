#pragma once

#include <chrono>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "engine_loader.h"
#include "flutter_embedder.h"
#if RACCOON_HAS_GL
#include "gl_renderer.h"
#else
namespace raccoon {
// Without a GPU renderer there are no GPU buffers; the type stays so callers
// compile.
struct GpuBufferSet {
  uint32_t generation = 0;
  size_t width = 0;
  size_t height = 0;
  uint32_t fourcc = 0;
  uint64_t modifier = 0;
  std::vector<uint32_t> strides;
  std::vector<uint32_t> offsets;
  std::vector<int> fds;
};
}  // namespace raccoon
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
  // "auto" rasterizes on the GPU when EGL offers one and falls back to the
  // software renderer; "gl" insists; "software" never tries.
  std::string renderer = "auto";
};

// One engine on the software renderer: start, metrics, input, shutdown.
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

  // The VM service URI once the engine announced it, else empty.
  std::string vm_service_uri() const;
  // Which renderer rasterizes, for the log: "software", or "gl (...)".
  const std::string& renderer() const { return renderer_; }

  // GPU buffers: the engine draws into a ring of exported buffers and frames
  // are buffer indices (see GlRenderer). False, with why, without a GPU
  // renderer that exports.
  bool EnableGpuBuffers(size_t count, std::string* error);
  void DisableGpuBuffers();
  bool GpuBufferSetNow(GpuBufferSet* out) const;
  // |fence_fd|, when not -1, is signalled once the client's last use of the
  // buffer is done; owned from here.
  void ReleaseGpuBuffer(uint32_t generation, int index, int fence_fd = -1);

  SoftwareFrame& frame() { return frame_; }
  TextInput& text_input() { return text_input_; }
  PlatformTaskRunner& platform() { return *platform_; }
  std::chrono::steady_clock::time_point started() const { return started_; }

 private:
  static bool OnPresent(void* user_data, const void* allocation,
                        size_t row_bytes, size_t height);
#if RACCOON_HAS_GL
  static bool GlMakeCurrent(void* user_data);
  static bool GlClearCurrent(void* user_data);
  static bool GlMakeResourceCurrent(void* user_data);
  static uint32_t GlFbo(void* user_data, const FlutterFrameInfo* info);
  static bool GlPresent(void* user_data, const FlutterPresentInfo* info);
  static void* GlProc(void* user_data, const char* name);
  std::unique_ptr<GlRenderer> gl_;
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
  std::function<void()> on_wake_;
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
