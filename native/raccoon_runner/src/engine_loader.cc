#include "engine_loader.h"

#include <dlfcn.h>

namespace raccoon {

namespace {

// The embedder library inside a runtime directory: a bare shared object on
// Linux, the framework the Flutter bucket ships on macOS. That framework
// carries the Dart VM snapshot inside itself (the SDK's vm_snapshot_data for
// macOS is empty) and the engine looks it up among the process's global
// symbols, so the framework is loaded globally.
#if defined(__APPLE__)
constexpr char kEngineLibrary[] = "FlutterEmbedder.framework/FlutterEmbedder";
constexpr int kLoadFlags = RTLD_NOW | RTLD_GLOBAL;
#else
constexpr char kEngineLibrary[] = "libflutter_engine.so";
constexpr int kLoadFlags = RTLD_NOW | RTLD_LOCAL;
#endif

}  // namespace

EngineLoader::~EngineLoader() {
  if (handle_ != nullptr) dlclose(handle_);
}

bool EngineLoader::Load(const std::string& engine_dir, std::string* error) {
  const std::string path = engine_dir + "/" + kEngineLibrary;
  handle_ = dlopen(path.c_str(), kLoadFlags);
  if (handle_ == nullptr) {
    *error = std::string("dlopen failed: ") + dlerror();
    return false;
  }
  using GetProcAddressesFn = FlutterEngineResult (*)(FlutterEngineProcTable*);
  auto get_procs = reinterpret_cast<GetProcAddressesFn>(
      dlsym(handle_, "FlutterEngineGetProcAddresses"));
  if (get_procs == nullptr) {
    *error = "FlutterEngineGetProcAddresses not found in " + path;
    return false;
  }
  procs_.struct_size = sizeof(FlutterEngineProcTable);
  if (get_procs(&procs_) != kSuccess) {
    *error = "FlutterEngineGetProcAddresses failed";
    return false;
  }
  return true;
}

}  // namespace raccoon
