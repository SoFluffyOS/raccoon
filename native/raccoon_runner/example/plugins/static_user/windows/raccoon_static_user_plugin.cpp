// The `get` method answers raccoon_static_core's value: the same one the
// app set there only when both libraries are linked into one module.
#include "include/raccoon_static_user/raccoon_static_user_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <raccoon_static_core/raccoon_static_core_plugin.h>

#include <memory>

namespace {

// For as long as the process: its handler answers the app.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

}  // namespace

void RaccoonStaticUserPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows = flutter::PluginRegistrarManager::GetInstance()
                      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      windows->messenger(), "raccoon_static_user",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "get") {
      result->Success(flutter::EncodableValue(RaccoonStaticCoreValue()));
      return;
    }
    result->NotImplemented();
  });
}
