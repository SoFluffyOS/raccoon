// One value behind the `set` and `get` methods, in a static library: the
// state a plugin built on this one reads too, as long as both are linked
// into one module.
#include "include/raccoon_static_core/raccoon_static_core_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace {

int g_value = 0;
// For as long as the process: its handler answers the app.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

}  // namespace

int RaccoonStaticCoreValue() { return g_value; }

void RaccoonStaticCorePluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows = flutter::PluginRegistrarManager::GetInstance()
                      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      windows->messenger(), "raccoon_static_core",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "set") {
      if (const auto* value = std::get_if<int32_t>(call.arguments())) g_value = *value;
      result->Success();
      return;
    }
    if (call.method_name() == "get") {
      result->Success(flutter::EncodableValue(g_value));
      return;
    }
    result->NotImplemented();
  });
}
