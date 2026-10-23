// The shape of a Flutter Windows plugin, as `flutter create --template=plugin`
// makes one: a flutter::Plugin on the C++ client wrapper, a method channel
// on the registrar's messenger. The echo is answered from a message posted
// to the view's window, handled by a top-level window proc delegate, so it
// proves the host pumps the platform thread's messages. The `texture`
// method asks for a pixel-buffer texture of one colour, which a host whose
// renderer draws no textures declines.
#include "include/raccoon_echo/raccoon_echo_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace {

using flutter::EncodableValue;

// Posted to the view's window with a Pending as its lparam.
constexpr UINT kEchoMessage = WM_APP + 0x52;

struct Pending {
  std::string text;
  std::unique_ptr<flutter::MethodResult<EncodableValue>> result;
};

class RaccoonEchoPlugin : public flutter::Plugin {
 public:
  explicit RaccoonEchoPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar), pixels_(64 * 64 * 4) {
    // Orange, 64 by 64, in RGBA.
    for (size_t i = 0; i < pixels_.size(); i += 4) {
      pixels_[i] = 0xFF;
      pixels_[i + 1] = 0x8C;
      pixels_[i + 2] = 0x00;
      pixels_[i + 3] = 0xFF;
    }
    delegate_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [](HWND, UINT message, WPARAM, LPARAM lparam) -> std::optional<LRESULT> {
          if (message != kEchoMessage) return std::nullopt;
          std::unique_ptr<Pending> pending(reinterpret_cast<Pending*>(lparam));
          pending->result->Success(EncodableValue("echo: " + pending->text));
          return 0;
        });
  }

  ~RaccoonEchoPlugin() override {
    registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
  }

  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (call.method_name() == "echo") {
      const auto* text = std::get_if<std::string>(call.arguments());
      auto* pending = new Pending{text == nullptr ? "?" : *text, std::move(result)};
      flutter::FlutterView* view = registrar_->GetView();
      if (view == nullptr ||
          !PostMessage(view->GetNativeWindow(), kEchoMessage, 0,
                       reinterpret_cast<LPARAM>(pending))) {
        pending->result->Error("echo", "no window to post to");
        delete pending;
      }
      return;
    }
    if (call.method_name() == "texture") {
      if (texture_id_ < 0) {
        texture_ = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
            [this](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
              buffer_.buffer = pixels_.data();
              buffer_.width = 64;
              buffer_.height = 64;
              return &buffer_;
            }));
        texture_id_ = registrar_->texture_registrar()->RegisterTexture(texture_.get());
      }
      if (texture_id_ < 0) {
        result->Error("texture", "the host took no texture");
        return;
      }
      result->Success(EncodableValue(texture_id_));
      return;
    }
    result->NotImplemented();
  }

  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;

 private:
  flutter::PluginRegistrarWindows* registrar_;
  int delegate_ = 0;
  std::vector<uint8_t> pixels_;
  FlutterDesktopPixelBuffer buffer_{};
  std::unique_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;
};

}  // namespace

void RaccoonEchoPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows = flutter::PluginRegistrarManager::GetInstance()
                      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  auto plugin = std::make_unique<RaccoonEchoPlugin>(windows);
  plugin->channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      windows->messenger(), "raccoon_echo", &flutter::StandardMethodCodec::GetInstance());
  plugin->channel_->SetMethodCallHandler(
      [handler = plugin.get()](const auto& call, auto result) {
        handler->Handle(call, std::move(result));
      });
  windows->AddPlugin(std::move(plugin));
}
