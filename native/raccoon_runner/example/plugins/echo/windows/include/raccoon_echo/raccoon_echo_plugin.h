#ifndef RACCOON_ECHO_PLUGIN_H_
#define RACCOON_ECHO_PLUGIN_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

// What the app's generated registrant calls, by the pluginClass in the
// pubspec: <pluginClass>RegisterWithRegistrar.
FLUTTER_PLUGIN_EXPORT void RaccoonEchoPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // RACCOON_ECHO_PLUGIN_H_
