#if RACCOON_HAS_PLUGINS && defined(_WIN32)
// The Windows half of plugins.h: plugin DLLs on the runner's own
// flutter_windows.dll (src/flutter_windows), opened from beside the runner
// before any plugin, so their imports of that name land on it.
#include "plugins.h"

#include <windows.h>

#include <cstdio>

namespace raccoon {

namespace {

std::string LastError() {
  char text[256] = {};
  FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr,
                 GetLastError(), 0, text, sizeof(text), nullptr);
  std::string message = text;
  while (!message.empty() && (message.back() == '\n' || message.back() == '\r')) {
    message.pop_back();
  }
  return message;
}

// The directory the runner's executable is in, with a backslash.
std::string RunnerDirectory() {
  char path[MAX_PATH] = {};
  const DWORD length = GetModuleFileNameA(nullptr, path, MAX_PATH);
  std::string directory(path, length);
  return directory.substr(0, directory.find_last_of("\\/") + 1);
}

std::string Backslashed(std::string path) {
  for (char& c : path) {
    if (c == '/') c = '\\';
  }
  return path;
}

}  // namespace

PluginHost::PluginHost(Bridge bridge) : bridge_(std::move(bridge)) {
  c_bridge_.struct_size = sizeof(c_bridge_);
  c_bridge_.user_data = this;
  c_bridge_.send = SendPlatformMessage;
  c_bridge_.respond = SendPlatformMessageResponse;
}

PluginHost::~PluginHost() {
  // The libraries stay mapped: a plugin's objects may outlive this. Its
  // registrar's destruction handler is told, and its messenger goes quiet.
  if (detach_ != nullptr) detach_();
}

bool PluginHost::Prepare(const std::string&, std::string* error) {
  if (embedding_ != nullptr) return true;
  const std::string path = RunnerDirectory() + "flutter_windows.dll";
  HMODULE embedding = LoadLibraryExA(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (embedding == nullptr) {
    *error = "cannot open " + path + ": " + LastError();
    return false;
  }
  auto attach = reinterpret_cast<RaccoonWindowsAttachFn>(
      GetProcAddress(embedding, "RaccoonWindowsAttach"));
  registrar_ = reinterpret_cast<RaccoonWindowsRegistrarFn>(
      GetProcAddress(embedding, "RaccoonWindowsRegistrar"));
  handle_message_ = reinterpret_cast<RaccoonWindowsHandleMessageFn>(
      GetProcAddress(embedding, "RaccoonWindowsHandleMessage"));
  detach_ = reinterpret_cast<RaccoonWindowsDetachFn>(
      GetProcAddress(embedding, "RaccoonWindowsDetach"));
  if (attach == nullptr || registrar_ == nullptr || handle_message_ == nullptr ||
      detach_ == nullptr) {
    *error = path + " is not the runner's";
    detach_ = nullptr;
    return false;
  }
  if (!attach(&c_bridge_)) {
    *error = "no window for the plugins' view: " + LastError();
    return false;
  }
  embedding_ = embedding;
  return true;
}

bool PluginHost::Load(const PluginEntry& entry, std::string* error) {
  if (entry.library.empty() || entry.symbol.empty()) {
    *error = "no library or symbol";
    return false;
  }
  // What the plugin bundles beside itself is found there first.
  HMODULE handle = LoadLibraryExA(Backslashed(entry.library).c_str(), nullptr,
                                  LOAD_WITH_ALTERED_SEARCH_PATH);
  if (handle == nullptr) {
    *error = entry.library + ": " + LastError();
    return false;
  }
  using Register = void (*)(FlutterDesktopPluginRegistrarRef);
  auto register_plugin =
      reinterpret_cast<Register>(GetProcAddress(handle, entry.symbol.c_str()));
  if (register_plugin == nullptr) {
    *error = "no " + entry.symbol + " in " + entry.library;
    return false;
  }
  handles_.push_back(handle);
  register_plugin(registrar_(entry.name.c_str()));
  names_.push_back(entry.name);
  return true;
}

bool PluginHost::HandleMessage(const std::string& channel, const uint8_t* data, size_t size,
                               const FlutterPlatformMessageResponseHandle* handle) {
  return handle_message_ != nullptr && handle_message_(channel.c_str(), data, size, handle);
}

bool PluginHost::PopulateTexture(int64_t, size_t, size_t, FlutterOpenGLTexture*) {
  return false;
}

bool PluginHost::SendPlatformMessage(void* user_data, const char* channel,
                                     const uint8_t* data, size_t size,
                                     FlutterDesktopBinaryReply reply, void* reply_data) {
  auto* self = static_cast<PluginHost*>(user_data);
  std::function<void(const uint8_t*, size_t)> on_reply;
  if (reply != nullptr) {
    on_reply = [reply, reply_data](const uint8_t* answer, size_t answer_size) {
      reply(answer, answer_size, reply_data);
    };
  }
  self->bridge_.send(channel, data, size, std::move(on_reply));
  return true;
}

void PluginHost::SendPlatformMessageResponse(void* user_data,
                                             const FlutterDesktopMessageResponseHandle* handle,
                                             const uint8_t* data, size_t size) {
  static_cast<PluginHost*>(user_data)->bridge_.respond(handle, data, size);
}

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS && _WIN32
