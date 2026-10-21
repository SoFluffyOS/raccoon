#include "engine_host.h"

namespace raccoon {

namespace {

constexpr char kVmServiceMarker[] = "listening on ";

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

  started_ = std::chrono::steady_clock::now();
  const FlutterEngineResult result =
      procs.Run(FLUTTER_ENGINE_VERSION, &renderer, &args, this, &engine_);
  if (result != kSuccess) {
    *error = "FlutterEngineRun failed with " + std::to_string(result);
    return false;
  }
  platform_->SetEngine(engine_);
  Resize(options.width, options.height, options.pixel_ratio);
  return true;
}

void EngineHost::Resize(size_t width, size_t height, double pixel_ratio) {
  FlutterWindowMetricsEvent metrics{};
  metrics.struct_size = sizeof(FlutterWindowMetricsEvent);
  metrics.width = width;
  metrics.height = height;
  metrics.pixel_ratio = pixel_ratio;
  loader_.procs().SendWindowMetricsEvent(engine_, &metrics);
}

void EngineHost::SendPointer(const FlutterPointerEvent& event) {
  loader_.procs().SendPointerEvent(engine_, &event, 1);
}

void EngineHost::SendKey(const FlutterKeyEvent& event) {
  loader_.procs().SendKeyEvent(
      engine_, &event, [](bool /*handled*/, void* /*user_data*/) {}, nullptr);
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
