// The host side of Raccoon's GPU buffers on Windows. Dart asks for a
// texture, names the runner's GPU socket, then names each frame's buffer;
// this side takes the runner's description of its ring from that socket,
// a shared D3D11 texture per buffer named by its handle, and hands Flutter
// the handle of the latest frame whenever it asks: a GPU surface texture of
// type DXGI shared handle, which Flutter opens on its own device.
//
// Channel raccoon_view/gpu: create() -> textureId; connect(textureId,
// socket) -> whether buffers go back from here; show(textureId, generation,
// index); dispose(textureId).
//
// No fence crosses the socket: the runner names a frame only once its GPU
// has drawn it, and a buffer goes back to the runner over the same socket
// ('RREL') once the next one is bound, by when the drawing that read it last
// was submitted a frame earlier.
#include "include/raccoon_view/raccoon_view_plugin.h"

#include <winsock2.h>
#include <afunix.h>
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <cstdint>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// More buffers than a ring will ever have.
constexpr uint32_t kMaxBuffers = 16;

uint32_t Read32(const uint8_t* at) {
  return static_cast<uint32_t>(at[0]) | (static_cast<uint32_t>(at[1]) << 8) |
         (static_cast<uint32_t>(at[2]) << 16) | (static_cast<uint32_t>(at[3]) << 24);
}

void Put32(uint8_t* at, uint32_t value) {
  for (int i = 0; i < 4; ++i) at[i] = static_cast<uint8_t>(value >> (8 * i));
}

// One set of buffers as the runner described it: each texture's shared
// handle, in index order.
struct BufferSet {
  uint32_t generation = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<HANDLE> handles;
};

// ---- The texture ---------------------------------------------------------

class GpuTexture {
 public:
  GpuTexture()
      : variant_(flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
            [this](size_t, size_t) -> const FlutterDesktopGpuSurfaceDescriptor* {
              return Surface();
            })) {}

  ~GpuTexture() { Close(); }

  flutter::TextureVariant* variant() { return &variant_; }

  // Tells Flutter a new frame is ready; called from the reader's thread,
  // which the registrar allows.
  void SetFrameAvailable(std::function<void()> frame_available) {
    frame_available_ = std::move(frame_available);
  }

  bool Connect(const std::string& path) {
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) return false;
    std::memcpy(address.sun_path, path.c_str(), path.size());
    const SOCKET socket = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket == INVALID_SOCKET) return false;
    if (connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
      closesocket(socket);
      return false;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      socket_ = socket;
    }
    reader_ = std::thread([this, socket] { Read(socket); });
    return true;
  }

  // Frame |index| of |generation| is the one to show next.
  void Show(uint32_t generation, int index) {
    std::lock_guard<std::mutex> lock(mutex_);
    // A frame named but never bound (Flutter did not get to it) was never
    // read: the runner's again at once.
    const bool superseded =
        shown_index_ >= 0 && (shown_index_ != index || shown_generation_ != generation);
    const bool unbound = shown_index_ != bound_index_ || shown_generation_ != bound_generation_;
    if (superseded && unbound) SendRelease(shown_generation_, shown_index_);
    shown_generation_ = generation;
    shown_index_ = index;
  }

  void Close() {
    SOCKET socket;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      socket = socket_;
      socket_ = INVALID_SOCKET;
    }
    // Closing is what ends a blocking recv on Winsock; a shutdown first
    // tells the runner at once.
    if (socket != INVALID_SOCKET) {
      shutdown(socket, SD_BOTH);
      closesocket(socket);
    }
    if (reader_.joinable()) reader_.join();
  }

 private:
  // On the raster thread: the latest frame's texture.
  const FlutterDesktopGpuSurfaceDescriptor* Surface() {
    std::lock_guard<std::mutex> lock(mutex_);
    // A new ring waits until a frame of it is named: until then the frame
    // shown is of the set at hand, and the new ring's buffers may be being
    // drawn or never drawn.
    if (pending_ && (!current_ || pending_->generation == shown_generation_)) {
      current_ = std::move(pending_);
    }
    if (!current_ || current_->handles.empty()) return nullptr;
    const BufferSet& set = *current_;
    // The frame named is not of this set: the buffer bound last stays, or,
    // with nothing of this set bound yet, the first, and not one to give
    // back.
    int index = 0;
    if (bound_generation_ == set.generation && bound_index_ >= 0 &&
        static_cast<size_t>(bound_index_) < set.handles.size()) {
      index = bound_index_;
    }
    if (shown_generation_ == set.generation && shown_index_ >= 0 &&
        static_cast<size_t>(shown_index_) < set.handles.size()) {
      index = shown_index_;
      const bool rebound =
          bound_index_ != shown_index_ || bound_generation_ != set.generation;
      // The buffer bound before was last read by the frame drawn before
      // this one: the runner's again.
      if (rebound && bound_index_ >= 0) SendRelease(bound_generation_, bound_index_);
      bound_generation_ = set.generation;
      bound_index_ = shown_index_;
    }
    descriptor_ = {};
    descriptor_.struct_size = sizeof(descriptor_);
    descriptor_.handle = set.handles[index];
    descriptor_.width = descriptor_.visible_width = set.width;
    descriptor_.height = descriptor_.visible_height = set.height;
    descriptor_.format = kFlutterDesktopPixelFormatBGRA8888;
    return &descriptor_;
  }

  // Gives buffer |index| of |generation| back to the runner: 'RREL',
  // generation, index, fenced (0: nothing rides along). Mutex held.
  void SendRelease(uint32_t generation, int index) {
    if (socket_ == INVALID_SOCKET) return;
    uint8_t message[4 + 16] = {16, 0, 0, 0, 'R', 'R', 'E', 'L'};
    Put32(message + 8, generation);
    Put32(message + 12, static_cast<uint32_t>(index));
    Put32(message + 16, 0);
    send(socket_, reinterpret_cast<const char*>(message), sizeof(message), 0);
  }

  // The reader's thread: the framed sets, 'RGPU', generation, count, width,
  // height, fourcc, modifier (64 bits), count pairs of stride and offset,
  // then count shared handles, until the runner hangs up.
  void Read(SOCKET socket) {
    std::vector<uint8_t> inbox;
    char buffer[16 * 1024];
    while (true) {
      const int got = recv(socket, buffer, sizeof(buffer), 0);
      if (got <= 0) return;
      inbox.insert(inbox.end(), buffer, buffer + got);
      size_t offset = 0;
      while (inbox.size() - offset >= 4) {
        const uint32_t length = Read32(inbox.data() + offset);
        if (inbox.size() - offset - 4 < length) break;
        const uint8_t* payload = inbox.data() + offset + 4;
        offset += 4 + length;
        if (length < 32 || std::memcmp(payload, "RGPU", 4) != 0) continue;
        const uint32_t count = Read32(payload + 8);
        // No handles, or a count no ring has; in 64 bits, so it cannot wrap.
        if (count > kMaxBuffers || length < 32 + static_cast<uint64_t>(count) * 12) continue;
        auto set = std::make_unique<BufferSet>();
        set->generation = Read32(payload + 4);
        set->width = Read32(payload + 12);
        set->height = Read32(payload + 16);
        const uint8_t* handles = payload + 32 + count * 8;
        for (uint32_t i = 0; i < count; ++i) {
          set->handles.push_back(
              reinterpret_cast<HANDLE>(static_cast<uintptr_t>(Read32(handles + i * 4))));
        }
        bool named;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          named = set->generation == shown_generation_;
          pending_ = std::move(set);
        }
        // The frame was named before its set came: Flutter asked for it
        // then and keeps what it got, so it must ask again, or an idle
        // app's pane stays as it was.
        if (named && frame_available_) frame_available_();
      }
      inbox.erase(inbox.begin(), inbox.begin() + offset);
    }
  }

  flutter::TextureVariant variant_;
  // Set before the reader starts and not changed after.
  std::function<void()> frame_available_;
  FlutterDesktopGpuSurfaceDescriptor descriptor_{};
  std::mutex mutex_;
  // The set waiting to be shown, and the one shown; the raster thread takes
  // pending over when Flutter asks for a surface.
  std::unique_ptr<BufferSet> pending_;
  std::unique_ptr<BufferSet> current_;
  uint32_t shown_generation_ = 0;
  int shown_index_ = -1;
  // The buffer handed to Flutter last, -1 for none: given back once another
  // is.
  uint32_t bound_generation_ = 0;
  int bound_index_ = -1;
  SOCKET socket_ = INVALID_SOCKET;
  std::thread reader_;
};

// ---- The plugin ----------------------------------------------------------

class RaccoonViewPlugin : public flutter::Plugin {
 public:
  explicit RaccoonViewPlugin(flutter::PluginRegistrarWindows* registrar)
      : textures_(registrar->texture_registrar()) {
    WSADATA data;
    WSAStartup(MAKEWORD(2, 2), &data);
  }

  ~RaccoonViewPlugin() override {
    for (auto& [id, texture] : live_) texture->Close();
    WSACleanup();
  }

  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (call.method_name() == "create") {
      auto texture = std::make_shared<GpuTexture>();
      const int64_t id = textures_->RegisterTexture(texture->variant());
      texture->SetFrameAvailable(
          [registrar = textures_, id] { registrar->MarkTextureFrameAvailable(id); });
      live_[id] = std::move(texture);
      result->Success(EncodableValue(id));
      return;
    }
    const auto* arguments = std::get_if<EncodableMap>(call.arguments());
    const int64_t id = Int(arguments, "textureId");
    const auto found = live_.find(id);
    if (found == live_.end()) {
      result->Error("unknown", "no such texture");
      return;
    }
    GpuTexture& texture = *found->second;
    if (call.method_name() == "connect") {
      const auto* socket = Get<std::string>(arguments, "socket");
      if (socket == nullptr || !texture.Connect(*socket)) {
        result->Error("connect", "could not connect to the GPU socket");
        return;
      }
      // Buffers go back from here, once drawn.
      result->Success(EncodableValue(true));
      return;
    }
    if (call.method_name() == "show") {
      texture.Show(static_cast<uint32_t>(Int(arguments, "generation")),
                   static_cast<int>(Int(arguments, "index")));
      textures_->MarkTextureFrameAvailable(id);
      result->Success();
      return;
    }
    if (call.method_name() == "dispose") {
      std::shared_ptr<GpuTexture> gone = std::move(found->second);
      live_.erase(found);
      gone->Close();
      // Flutter lets go of the texture on its own time; it lives until then.
      textures_->UnregisterTexture(id, [gone]() {});
      result->Success();
      return;
    }
    result->NotImplemented();
  }

  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;

 private:
  template <typename T>
  static const T* Get(const EncodableMap* arguments, const char* key) {
    if (arguments == nullptr) return nullptr;
    const auto it = arguments->find(EncodableValue(key));
    return it == arguments->end() ? nullptr : std::get_if<T>(&it->second);
  }

  // An integer argument, whichever width the codec gave it.
  static int64_t Int(const EncodableMap* arguments, const char* key) {
    if (const auto* narrow = Get<int32_t>(arguments, key)) return *narrow;
    if (const auto* wide = Get<int64_t>(arguments, key)) return *wide;
    return -1;
  }

  flutter::TextureRegistrar* textures_;
  std::map<int64_t, std::shared_ptr<GpuTexture>> live_;
};

}  // namespace

void RaccoonViewPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows = flutter::PluginRegistrarManager::GetInstance()
                      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  auto plugin = std::make_unique<RaccoonViewPlugin>(windows);
  plugin->channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      windows->messenger(), "raccoon_view/gpu", &flutter::StandardMethodCodec::GetInstance());
  plugin->channel_->SetMethodCallHandler(
      [handler = plugin.get()](const auto& call, auto result) {
        handler->Handle(call, std::move(result));
      });
  windows->AddPlugin(std::move(plugin));
}
