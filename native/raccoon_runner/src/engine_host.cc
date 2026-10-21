#include "engine_host.h"

namespace raccoon {

namespace {

constexpr char kVmServiceMarker[] = "listening on ";
// The one display the runner reports; window metrics name it.
constexpr FlutterEngineDisplayId kDisplayId = 0;

}  // namespace

bool EngineHost::Start(const EngineOptions& options, LogCallback on_log,
                       std::function<void()> on_wake, std::string* error) {
  if (!loader_.Load(options.engine_dir, error)) return false;
  const FlutterEngineProcTable& procs = loader_.procs();

  on_log_ = std::move(on_log);
  on_wake_ = std::move(on_wake);
  assets_ = options.assets;
  icu_ = options.icu;

  platform_ = std::make_unique<PlatformTaskRunner>(procs);
  platform_->SetWakeCallback(on_wake_);
  frame_.SetPresentedCallback(on_wake_);

  FlutterRendererConfig renderer{};
  renderer.type = kSoftware;
  renderer.software.struct_size = sizeof(FlutterSoftwareRendererConfig);
  renderer.software.surface_present_callback = OnPresent;

  command_line_ = {"raccoon_runner", "--enable-impeller=false"};
  for (const std::string& arg : options.extra_args) command_line_.push_back(arg);
  argv_.clear();
  for (const std::string& arg : command_line_) argv_.push_back(arg.c_str());

  runners_.struct_size = sizeof(FlutterCustomTaskRunners);
  runners_.platform_task_runner = &platform_->description();

  FlutterProjectArgs args{};
  args.struct_size = sizeof(FlutterProjectArgs);
  args.assets_path = assets_.c_str();
  args.icu_data_path = icu_.c_str();
  args.command_line_argc = static_cast<int>(argv_.size());
  args.command_line_argv = argv_.data();
  args.log_message_callback = OnLog;
  args.log_tag = "raccoon";
  args.custom_task_runners = &runners_;
  args.platform_message_callback = OnPlatformMessage;

  started_ = std::chrono::steady_clock::now();
  const FlutterEngineResult result =
      procs.Run(FLUTTER_ENGINE_VERSION, &renderer, &args, this, &engine_);
  if (result != kSuccess) {
    *error = "FlutterEngineRun failed with " + std::to_string(result);
    return false;
  }
  platform_->SetEngine(engine_);
  // Report one display, as desktop embedders do once the engine runs; apps
  // that read PlatformDispatcher.displays (Wonderous does) find it. Calling
  // this before the engine runs crashes inside the engine.
  FlutterEngineDisplay display{};
  display.struct_size = sizeof(FlutterEngineDisplay);
  display.display_id = kDisplayId;
  display.single_display = true;
  display.refresh_rate = 60.0;
  display.width = options.width;
  display.height = options.height;
  display.device_pixel_ratio = options.pixel_ratio;
  procs.NotifyDisplayUpdate(engine_, kFlutterEngineDisplaysUpdateTypeStartup,
                            &display, 1);
  Resize(options.width, options.height, options.pixel_ratio);
  return true;
}

void EngineHost::Resize(size_t width, size_t height, double pixel_ratio) {
  FlutterWindowMetricsEvent metrics{};
  metrics.struct_size = sizeof(FlutterWindowMetricsEvent);
  metrics.width = width;
  metrics.height = height;
  metrics.pixel_ratio = pixel_ratio;
  metrics.display_id = kDisplayId;
  loader_.procs().SendWindowMetricsEvent(engine_, &metrics);
  windows_.SetViewSize(width, height, pixel_ratio);
}

void EngineHost::SendPointer(const FlutterPointerEvent& event) {
  loader_.procs().SendPointerEvent(engine_, &event, 1);
}

void EngineHost::SendKey(const FlutterKeyEvent& event) {
  loader_.procs().SendKeyEvent(
      engine_, &event, [](bool /*handled*/, void* /*user_data*/) {}, nullptr);
}

void EngineHost::Respond(const FlutterPlatformMessageResponseHandle* handle,
                         const uint8_t* data, size_t size) {
  if (engine_ == nullptr || handle == nullptr) return;
  loader_.procs().SendPlatformMessageResponse(engine_, handle, data, size);
}

void EngineHost::OnPlatformMessage(const FlutterPlatformMessage* message,
                                   void* user_data) {
  auto* host = static_cast<EngineHost*>(user_data);
  const std::string channel = message->channel == nullptr ? "" : message->channel;
  // The window channels are the runner's own: it is the app's window host,
  // and apps call them at startup, before a client may be connected.
  std::vector<uint8_t> reply;
  if (host->windows_.Handle(channel, message->message, message->message_size,
                            &reply)) {
    host->Respond(message->response_handle, reply.data(), reply.size());
    return;
  }
  if (host->on_platform_message_) {
    host->on_platform_message_(channel, message->message, message->message_size,
                               message->response_handle);
    return;
  }
  host->Respond(message->response_handle, nullptr, 0);
}

void EngineHost::Shutdown() {
  if (engine_ == nullptr) return;
  platform_->RunDueTasks();
  loader_.procs().Shutdown(engine_);
  engine_ = nullptr;
}

std::string EngineHost::vm_service_uri() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return vm_service_uri_;
}

bool EngineHost::OnPresent(void* user_data, const void* allocation,
                           size_t row_bytes, size_t height) {
  static_cast<EngineHost*>(user_data)->frame_.Present(allocation, row_bytes,
                                                      height);
  return true;
}

void EngineHost::OnLog(const char* tag, const char* message, void* user_data) {
  auto* host = static_cast<EngineHost*>(user_data);
  const std::string text = message == nullptr ? "" : message;
  const size_t marker = text.find(kVmServiceMarker);
  if (marker != std::string::npos && text.find("VM service") != std::string::npos) {
    std::string uri = text.substr(marker + sizeof(kVmServiceMarker) - 1);
    while (!uri.empty() && (uri.back() == '\n' || uri.back() == ' ')) uri.pop_back();
    {
      std::lock_guard<std::mutex> lock(host->mutex_);
      host->vm_service_uri_ = uri;
    }
    if (host->on_wake_) host->on_wake_();
  }
  if (host->on_log_) host->on_log_(tag == nullptr ? "" : tag, text);
}

}  // namespace raccoon
