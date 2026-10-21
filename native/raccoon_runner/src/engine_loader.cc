#include "engine_loader.h"

#include <dlfcn.h>

namespace raccoon {

EngineLoader::~EngineLoader() {
  if (handle_ != nullptr) dlclose(handle_);
}

bool EngineLoader::Load(const std::string& engine_dir, std::string* error) {
  const std::string path = engine_dir + "/libflutter_engine.so";
  handle_ = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
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
