#ifndef RACCOON_STATIC_CORE_PLUGIN_H_
#define RACCOON_STATIC_CORE_PLUGIN_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void RaccoonStaticCorePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

// The value the `set` method keeps, for raccoon_static_user, which links
// this library, as firebase_auth links firebase_core's app.
int RaccoonStaticCoreValue();

#endif  // RACCOON_STATIC_CORE_PLUGIN_H_
