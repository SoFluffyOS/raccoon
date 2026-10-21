#pragma once

#include <chrono>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "engine_loader.h"
#include "flutter_embedder.h"
#include "platform_task_runner.h"
#include "software_frame.h"

namespace raccoon {

struct EngineOptions {
  std::string engine_dir;
  std::string assets;
  std::string icu;
  size_t width = 800;
  size_t height = 600;
  double pixel_ratio = 1.0;
  // Engine switches appended to the command line, e.g. --vm-service-port=N.
  std::vector<std::string> extra_args;
};

// One engine on the software renderer: start, metrics, input, shutdown.
class EngineHost {
 public:
  using LogCallback =
      std::function<void(const std::string& tag, const std::string& message)>;
  // A platform channel message from the app. |handle| is null when the app
  // expects no reply; otherwise Respond must be called with it exactly once.
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
  void SendKey(const FlutterKeyEvent& event);
  void Shutdown();

  // Microseconds on the engine's clock.
  uint64_t NowMicros() const { return loader_.procs().GetCurrentTime() / 1000; }

  // The VM service URI once the engine announced it, else empty.
  std::string vm_service_uri() const;

  SoftwareFrame& frame() { return frame_; }
  PlatformTaskRunner& platform() { return *platform_; }
  std::chrono::steady_clock::time_point started() const { return started_; }

 private:
  static bool OnPresent(void* user_data, const void* allocation,
                        size_t row_bytes, size_t height);
  static void OnLog(const char* tag, const char* message, void* user_data);
  static void OnPlatformMessage(const FlutterPlatformMessage* message,
                                void* user_data);

  EngineLoader loader_;
  std::unique_ptr<PlatformTaskRunner> platform_;
  SoftwareFrame frame_;
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
