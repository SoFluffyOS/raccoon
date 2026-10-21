#include "engine_host.h"

#include <nlohmann/json.hpp>

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
  if (!options.data_dir.empty()) {
    user_defaults_.SetStorePath(options.data_dir + "/shared_preferences.bin");
  }
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
  text_input_.SetSender([this](const std::string& channel, const std::string& json) {
    SendPlatformMessage(channel, reinterpret_cast<const uint8_t*>(json.data()),
                        json.size());
  });
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

namespace {

struct ReplyContext {
  std::function<void(const uint8_t* data, size_t size)> on_reply;
};

void OnReply(const uint8_t* data, size_t size, void* user_data) {
  auto* context = static_cast<ReplyContext*>(user_data);
  context->on_reply(data, size);
  delete context;
}

// The first code point of a UTF-8 string, 0 for none.
uint32_t FirstCodePoint(const std::string& utf8) {
  if (utf8.empty()) return 0;
  const unsigned char c = utf8[0];
  size_t length = 1;
  uint32_t code = c;
  if ((c & 0xE0) == 0xC0) {
    length = 2;
    code = c & 0x1F;
  } else if ((c & 0xF0) == 0xE0) {
    length = 3;
    code = c & 0x0F;
  } else if ((c & 0xF8) == 0xF0) {
    length = 4;
    code = c & 0x07;
  }
  if (utf8.size() < length) return 0;
  for (size_t k = 1; k < length; ++k) {
    code = (code << 6) | (static_cast<unsigned char>(utf8[k]) & 0x3F);
  }
  return code;
}

}  // namespace

void EngineHost::TrackModifiers(const FlutterKeyEvent& event) {
  const bool down = event.type != kFlutterKeyEventTypeUp;
  switch (event.logical) {
    case 0x200000100: case 0x200000101: control_ = down; break;
    case 0x200000102: case 0x200000103: shift_ = down; break;
    case 0x200000104: case 0x200000105: alt_ = down; break;
    case 0x200000106: case 0x200000107: meta_ = down; break;
    default: break;
  }
}

std::string EngineHost::RawKeyMessage(const FlutterKeyEvent& event,
                                      const std::string& character) const {
  // The framework reads this message by host keymap; only the logical key
  // and the character matter to it, the rest feeds the deprecated RawKeyboard.
  nlohmann::json message;
  message["type"] = event.type == kFlutterKeyEventTypeUp ? "keyup" : "keydown";
  message["specifiedLogicalKey"] = event.logical;
#if defined(__APPLE__)
  message["keymap"] = "macos";
  message["keyCode"] = 0;
  message["characters"] = character;
  message["charactersIgnoringModifiers"] = character;
  message["modifiers"] = (shift_ ? 0x20000 : 0) | (control_ ? 0x40000 : 0) |
                         (alt_ ? 0x80000 : 0) | (meta_ ? 0x100000 : 0);
#elif defined(_WIN32)
  message["keymap"] = "windows";
  message["keyCode"] = 0;
  message["scanCode"] = 0;
  message["characterCodePoint"] = FirstCodePoint(character);
  message["modifiers"] = 0;
#else
  message["keymap"] = "linux";
  message["toolkit"] = "gtk";
  message["keyCode"] = 0;
  message["scanCode"] = 0;
  message["unicodeScalarValues"] = FirstCodePoint(character);
  message["modifiers"] = (shift_ ? 1 << 0 : 0) | (control_ ? 1 << 2 : 0) |
                         (alt_ ? 1 << 3 : 0) | (meta_ ? 1 << 26 : 0);
#endif
  return message.dump();
}

void EngineHost::SendKey(const FlutterKeyEvent& event) {
  TrackModifiers(event);
  loader_.procs().SendKeyEvent(
      engine_, &event, [](bool /*handled*/, void* /*user_data*/) {}, nullptr);
  if (event.synthesized) return;
  // The framework holds key data until the legacy flutter/keyevent message
  // for the same key arrives, and answers that one with whether it handled
  // the key. A key down it leaves alone edits the text field, if any.
  const std::string character =
      event.character == nullptr ? std::string() : event.character;
  const bool down = event.type != kFlutterKeyEventTypeUp;
  const std::string raw = RawKeyMessage(event, character);
  const uint64_t logical = event.logical;
  SendPlatformMessage(
      "flutter/keyevent", reinterpret_cast<const uint8_t*>(raw.data()),
      raw.size(), [this, down, logical, character](const uint8_t* data, size_t size) {
        if (!down) return;
        const auto reply = nlohmann::json::parse(data, data + size, nullptr, false);
        const bool handled = reply.is_object() && reply.contains("handled") &&
                             reply["handled"].is_boolean() &&
                             reply["handled"].get<bool>();
        if (handled) return;
        text_input_.HandleKey(logical, character, shift_, control_, alt_, meta_);
      });
}

void EngineHost::SendPlatformMessage(
    const std::string& channel, const uint8_t* data, size_t size,
    std::function<void(const uint8_t* data, size_t size)> on_reply) {
  if (engine_ == nullptr) return;
  const auto& procs = loader_.procs();
  FlutterPlatformMessageResponseHandle* handle = nullptr;
  if (on_reply) {
    auto* context = new ReplyContext{std::move(on_reply)};
    if (procs.PlatformMessageCreateResponseHandle(engine_, OnReply, context,
                                                  &handle) != kSuccess) {
      delete context;
      handle = nullptr;
    }
  }
  FlutterPlatformMessage message{};
  message.struct_size = sizeof(FlutterPlatformMessage);
  message.channel = channel.c_str();
  message.message = data;
  message.message_size = size;
  message.response_handle = handle;
  procs.SendPlatformMessage(engine_, &message);
  if (handle != nullptr) {
    procs.PlatformMessageReleaseResponseHandle(engine_, handle);
  }
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
  // The window and shared preferences channels are the runner's own: it is
  // the app's window host, and apps call them at startup, before a client may
  // be connected.
  std::vector<uint8_t> reply;
  if (host->windows_.Handle(channel, message->message, message->message_size,
                            &reply) ||
      host->user_defaults_.Handle(channel, message->message,
                                  message->message_size, &reply) ||
      host->text_input_.Handle(channel, message->message,
                               message->message_size, &reply)) {
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
