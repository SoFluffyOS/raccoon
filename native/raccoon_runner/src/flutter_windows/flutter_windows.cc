// flutter_windows.dll, the runner's: the C API of Flutter's Windows
// embedding that plugins call (third_party/flutter_windows), implemented
// over the runner's engine through raccoon_bridge.h. Plugin binaries import
// flutter_windows.dll by name, and Windows hands them this one, which the
// runner opened first. One messenger, one view, a registrar per plugin.
// The app's own engine and view controller calls are a Windows app runner's
// business, not a plugin's; they are here so every import resolves, and do
// nothing.

#include <windows.h>
#include <shellscalingapi.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "flutter_messenger.h"
#include "flutter_plugin_registrar.h"
#include "flutter_texture_registrar.h"
#include "flutter_windows.h"
#include "raccoon_bridge.h"

struct FlutterDesktopMessenger {
  std::atomic<int> references{1};
  // Held by plugins around calls from other threads, so the engine does not
  // go between their availability check and their call.
  std::recursive_mutex lock;
  bool available = false;
};

struct FlutterDesktopTextureRegistrar {};

struct FlutterDesktopView {
  HWND hwnd = nullptr;
};

struct FlutterDesktopPluginRegistrar {
  std::string plugin;
  FlutterDesktopOnPluginRegistrarDestroyed on_destroyed = nullptr;
};

namespace {

constexpr wchar_t kViewClass[] = L"RaccoonPluginView";

struct Callback {
  FlutterDesktopMessageCallback callback;
  void* user_data;
};

struct WindowProcDelegate {
  FlutterDesktopWindowProcCallback callback;
  void* user_data;
};

struct Shim {
  RaccoonWindowsBridge bridge{};
  FlutterDesktopMessenger messenger;
  FlutterDesktopTextureRegistrar textures;
  FlutterDesktopView view;
  std::mutex mutex;
  std::unordered_map<std::string, Callback> callbacks;
  std::vector<WindowProcDelegate> delegates;
  std::vector<std::unique_ptr<FlutterDesktopPluginRegistrar>> registrars;
};

Shim& shim() {
  static Shim* instance = new Shim();  // lives as long as the process
  return *instance;
}

// The view's window procedure: the plugins' top-level delegates first, in
// the order they came, as Flutter's runner hands them its window's messages.
LRESULT CALLBACK ViewProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  std::vector<WindowProcDelegate> delegates;
  {
    std::lock_guard<std::mutex> lock(shim().mutex);
    delegates = shim().delegates;
  }
  for (const WindowProcDelegate& delegate : delegates) {
    LRESULT result = 0;
    if (delegate.callback(hwnd, message, wparam, lparam, delegate.user_data, &result)) {
      return result;
    }
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// A top-level window that is never shown: what plugins parent their dialogs
// to and post their messages at. The app's real window is the client's pane.
HWND MakeViewWindow() {
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = ViewProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kViewClass;
  RegisterClassExW(&window_class);
  return CreateWindowExW(0, kViewClass, L"Raccoon", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
                         CW_USEDEFAULT, 800, 600, nullptr, nullptr,
                         window_class.hInstance, nullptr);
}

}  // namespace

// ---- The runner's side ------------------------------------------------------

extern "C" {

__declspec(dllexport) bool RaccoonWindowsAttach(const RaccoonWindowsBridge* bridge) {
  Shim& state = shim();
  state.bridge = *bridge;
  if (state.view.hwnd == nullptr) state.view.hwnd = MakeViewWindow();
  std::lock_guard<std::recursive_mutex> lock(state.messenger.lock);
  state.messenger.available = true;
  return state.view.hwnd != nullptr;
}

__declspec(dllexport) FlutterDesktopPluginRegistrarRef RaccoonWindowsRegistrar(
    const char* plugin) {
  auto registrar = std::make_unique<FlutterDesktopPluginRegistrar>();
  registrar->plugin = plugin == nullptr ? "" : plugin;
  std::lock_guard<std::mutex> lock(shim().mutex);
  shim().registrars.push_back(std::move(registrar));
  return shim().registrars.back().get();
}

__declspec(dllexport) bool RaccoonWindowsHandleMessage(
    const char* channel, const uint8_t* data, size_t size,
    const FlutterDesktopMessageResponseHandle* handle) {
  Callback found{};
  {
    std::lock_guard<std::mutex> lock(shim().mutex);
    const auto it = shim().callbacks.find(channel);
    if (it == shim().callbacks.end()) return false;
    found = it->second;
  }
  FlutterDesktopMessage message{};
  message.struct_size = sizeof(message);
  message.channel = channel;
  message.message = data;
  message.message_size = size;
  message.response_handle = handle;
  found.callback(&shim().messenger, &message, found.user_data);
  return true;
}

__declspec(dllexport) void RaccoonWindowsDetach() {
  Shim& state = shim();
  std::vector<FlutterDesktopPluginRegistrar*> registrars;
  {
    std::lock_guard<std::mutex> lock(state.mutex);
    for (const auto& registrar : state.registrars) registrars.push_back(registrar.get());
  }
  for (FlutterDesktopPluginRegistrar* registrar : registrars) {
    if (registrar->on_destroyed != nullptr) registrar->on_destroyed(registrar);
  }
  std::lock_guard<std::recursive_mutex> lock(state.messenger.lock);
  state.messenger.available = false;
}

// ---- The messenger ----------------------------------------------------------

bool FlutterDesktopMessengerSend(FlutterDesktopMessengerRef messenger, const char* channel,
                                 const uint8_t* message, const size_t message_size) {
  return FlutterDesktopMessengerSendWithReply(messenger, channel, message, message_size,
                                              nullptr, nullptr);
}

bool FlutterDesktopMessengerSendWithReply(FlutterDesktopMessengerRef messenger,
                                          const char* channel, const uint8_t* message,
                                          const size_t message_size,
                                          const FlutterDesktopBinaryReply reply,
                                          void* user_data) {
  std::lock_guard<std::recursive_mutex> lock(messenger->lock);
  const RaccoonWindowsBridge& bridge = shim().bridge;
  if (!messenger->available || bridge.send == nullptr) return false;
  return bridge.send(bridge.user_data, channel, message, message_size, reply, user_data);
}

void FlutterDesktopMessengerSendResponse(FlutterDesktopMessengerRef messenger,
                                         const FlutterDesktopMessageResponseHandle* handle,
                                         const uint8_t* data, size_t data_length) {
  std::lock_guard<std::recursive_mutex> lock(messenger->lock);
  const RaccoonWindowsBridge& bridge = shim().bridge;
  if (!messenger->available || bridge.respond == nullptr) return;
  bridge.respond(bridge.user_data, handle, data, data_length);
}

void FlutterDesktopMessengerSetCallback(FlutterDesktopMessengerRef, const char* channel,
                                        FlutterDesktopMessageCallback callback,
                                        void* user_data) {
  std::lock_guard<std::mutex> lock(shim().mutex);
  if (callback == nullptr) {
    shim().callbacks.erase(channel);
    return;
  }
  shim().callbacks[channel] = {callback, user_data};
}

FlutterDesktopMessengerRef FlutterDesktopMessengerAddRef(FlutterDesktopMessengerRef messenger) {
  ++messenger->references;
  return messenger;
}

// The messenger is the shim's own and outlives every plugin.
void FlutterDesktopMessengerRelease(FlutterDesktopMessengerRef messenger) {
  --messenger->references;
}

bool FlutterDesktopMessengerIsAvailable(FlutterDesktopMessengerRef messenger) {
  return messenger->available;
}

FlutterDesktopMessengerRef FlutterDesktopMessengerLock(FlutterDesktopMessengerRef messenger) {
  messenger->lock.lock();
  return messenger;
}

void FlutterDesktopMessengerUnlock(FlutterDesktopMessengerRef messenger) {
  messenger->lock.unlock();
}

// ---- The plugin registrar ---------------------------------------------------

FlutterDesktopMessengerRef FlutterDesktopPluginRegistrarGetMessenger(
    FlutterDesktopPluginRegistrarRef) {
  return &shim().messenger;
}

FlutterDesktopTextureRegistrarRef FlutterDesktopRegistrarGetTextureRegistrar(
    FlutterDesktopPluginRegistrarRef) {
  return &shim().textures;
}

void FlutterDesktopPluginRegistrarSetDestructionHandler(
    FlutterDesktopPluginRegistrarRef registrar,
    FlutterDesktopOnPluginRegistrarDestroyed callback) {
  registrar->on_destroyed = callback;
}

FlutterDesktopViewRef FlutterDesktopPluginRegistrarGetView(FlutterDesktopPluginRegistrarRef) {
  return &shim().view;
}

// One view, the implicit one, whose id is 0.
FlutterDesktopViewRef FlutterDesktopPluginRegistrarGetViewById(FlutterDesktopPluginRegistrarRef,
                                                               FlutterDesktopViewId view_id) {
  return view_id == 0 ? &shim().view : nullptr;
}

void FlutterDesktopPluginRegistrarRegisterTopLevelWindowProcDelegate(
    FlutterDesktopPluginRegistrarRef, FlutterDesktopWindowProcCallback delegate,
    void* user_data) {
  std::lock_guard<std::mutex> lock(shim().mutex);
  shim().delegates.push_back({delegate, user_data});
}

void FlutterDesktopPluginRegistrarUnregisterTopLevelWindowProcDelegate(
    FlutterDesktopPluginRegistrarRef, FlutterDesktopWindowProcCallback delegate) {
  std::lock_guard<std::mutex> lock(shim().mutex);
  auto& delegates = shim().delegates;
  for (auto it = delegates.begin(); it != delegates.end(); ++it) {
    if (it->callback == delegate) {
      delegates.erase(it);
      return;
    }
  }
}

// No GPU of the runner's is shared with plugins.
bool FlutterDesktopPluginRegistrarGetGraphicsAdapter(FlutterDesktopPluginRegistrarRef,
                                                     IDXGIAdapter** adapter_out) {
  if (adapter_out != nullptr) *adapter_out = nullptr;
  return false;
}

// ---- Textures ---------------------------------------------------------------
// The software renderer draws no external texture: none is taken.

int64_t FlutterDesktopTextureRegistrarRegisterExternalTexture(
    FlutterDesktopTextureRegistrarRef, const FlutterDesktopTextureInfo*) {
  return -1;
}

void FlutterDesktopTextureRegistrarUnregisterExternalTexture(FlutterDesktopTextureRegistrarRef,
                                                             int64_t,
                                                             void (*callback)(void*),
                                                             void* user_data) {
  if (callback != nullptr) callback(user_data);
}

bool FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
    FlutterDesktopTextureRegistrarRef, int64_t) {
  return false;
}

// ---- The view and freestanding utilities ------------------------------------

HWND FlutterDesktopViewGetHWND(FlutterDesktopViewRef view) { return view->hwnd; }

IDXGIAdapter* FlutterDesktopViewGetGraphicsAdapter(FlutterDesktopViewRef) { return nullptr; }

UINT FlutterDesktopGetDpiForHWND(HWND hwnd) {
  if (hwnd != nullptr) {
    const UINT dpi = GetDpiForWindow(hwnd);
    if (dpi != 0) return dpi;
  }
  return FlutterDesktopGetDpiForMonitor(MonitorFromPoint({0, 0}, MONITOR_DEFAULTTOPRIMARY));
}

UINT FlutterDesktopGetDpiForMonitor(HMONITOR monitor) {
  UINT x = 96;
  UINT y = 96;
  if (monitor == nullptr || GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &x, &y) != S_OK) {
    return 96;
  }
  return x;
}

// The runner's streams are its own; nothing to reopen.
void FlutterDesktopResyncOutputStreams() {}

// ---- A Windows app runner's calls: no engine or view controller here --------

FlutterDesktopViewControllerRef FlutterDesktopViewControllerCreate(int, int,
                                                                   FlutterDesktopEngineRef) {
  return nullptr;
}

void FlutterDesktopViewControllerDestroy(FlutterDesktopViewControllerRef) {}

FlutterDesktopViewId FlutterDesktopViewControllerGetViewId(FlutterDesktopViewControllerRef) {
  return 0;
}

FlutterDesktopEngineRef FlutterDesktopViewControllerGetEngine(FlutterDesktopViewControllerRef) {
  return nullptr;
}

FlutterDesktopViewRef FlutterDesktopViewControllerGetView(FlutterDesktopViewControllerRef) {
  return nullptr;
}

void FlutterDesktopViewControllerForceRedraw(FlutterDesktopViewControllerRef) {}

bool FlutterDesktopViewControllerHandleTopLevelWindowProc(FlutterDesktopViewControllerRef, HWND,
                                                          UINT, WPARAM, LPARAM, LRESULT*) {
  return false;
}

FlutterDesktopEngineRef FlutterDesktopEngineCreate(const FlutterDesktopEngineProperties*) {
  return nullptr;
}

bool FlutterDesktopEngineDestroy(FlutterDesktopEngineRef) { return false; }

bool FlutterDesktopEngineRun(FlutterDesktopEngineRef, const char*) { return false; }

uint64_t FlutterDesktopEngineProcessMessages(FlutterDesktopEngineRef) { return 0; }

void FlutterDesktopEngineReloadSystemFonts(FlutterDesktopEngineRef) {}

FlutterDesktopPluginRegistrarRef FlutterDesktopEngineGetPluginRegistrar(FlutterDesktopEngineRef,
                                                                        const char*) {
  return nullptr;
}

FlutterDesktopMessengerRef FlutterDesktopEngineGetMessenger(FlutterDesktopEngineRef) {
  return nullptr;
}

FlutterDesktopTextureRegistrarRef FlutterDesktopEngineGetTextureRegistrar(
    FlutterDesktopEngineRef) {
  return nullptr;
}

void FlutterDesktopEngineSetNextFrameCallback(FlutterDesktopEngineRef, VoidCallback, void*) {}

bool FlutterDesktopEngineIsPlatformThread(FlutterDesktopEngineRef) { return false; }

void FlutterDesktopEnginePostPlatformThreadTask(FlutterDesktopEngineRef, VoidCallback,
                                                VoidCallback on_cancel, void* user_data) {
  if (on_cancel != nullptr) on_cancel(user_data);
}

bool FlutterDesktopEngineGetGraphicsAdapter(FlutterDesktopEngineRef,
                                            IDXGIAdapter** adapter_out) {
  if (adapter_out != nullptr) *adapter_out = nullptr;
  return false;
}

bool FlutterDesktopEngineProcessExternalWindowMessage(FlutterDesktopEngineRef, HWND, UINT,
                                                      WPARAM, LPARAM, LRESULT*) {
  return false;
}

// Flutter's DLL exports these too, outside its public headers: multiple
// windows and platform views. Nothing to look up or register here.
__declspec(dllexport) FlutterDesktopEngineRef FlutterDesktopEngineForId(int64_t) {
  return nullptr;
}

__declspec(dllexport) FlutterDesktopViewControllerRef FlutterDesktopEngineCreateViewController(
    FlutterDesktopEngineRef, const void*) {
  return nullptr;
}

__declspec(dllexport) void FlutterDesktopEngineRegisterPlatformViewType(FlutterDesktopEngineRef,
                                                                        const char*,
                                                                        const void*) {}

}  // extern "C"
