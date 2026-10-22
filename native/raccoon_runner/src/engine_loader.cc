#include "engine_loader.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace raccoon {

namespace {

// The embedder library inside a runtime directory: a bare shared object on
// Linux, the framework the Flutter bucket ships on macOS, a DLL on Windows.
// The macOS framework carries the Dart VM snapshot inside itself (the SDK's
// vm_snapshot_data for macOS is empty) and the engine looks it up among the
// process's global symbols, so the framework is loaded globally.
#if defined(_WIN32)
constexpr char kEngineLibrary[] = "flutter_engine.dll";
#elif defined(__APPLE__)
constexpr char kEngineLibrary[] = "FlutterEmbedder.framework/FlutterEmbedder";
constexpr int kLoadFlags = RTLD_NOW | RTLD_GLOBAL;
#else
constexpr char kEngineLibrary[] = "libflutter_engine.so";
constexpr int kLoadFlags = RTLD_NOW | RTLD_LOCAL;
#endif

#if defined(_WIN32)

void* OpenLibrary(const std::string& path, std::string* error) {
  // What the DLL needs is looked up next to it first, as the runtime
  // directory holds it; that search wants backslashes.
  std::string native = path;
  for (char& c : native) {
    if (c == '/') c = '\\';
  }
  HMODULE module = LoadLibraryExA(native.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (module == nullptr) {
    const DWORD code = GetLastError();
    char text[256] = {};
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, code,
                   0, text, sizeof(text), nullptr);
    *error = "LoadLibrary failed: " + path + ": " + text;
    while (!error->empty() && (error->back() == '\n' || error->back() == '\r')) {
      error->pop_back();
    }
  }
  return reinterpret_cast<void*>(module);
}

void* Symbol(void* handle, const char* name) {
  return reinterpret_cast<void*>(GetProcAddress(static_cast<HMODULE>(handle), name));
}

void CloseLibrary(void* handle) { FreeLibrary(static_cast<HMODULE>(handle)); }

#else

void* OpenLibrary(const std::string& path, std::string* error) {
  void* handle = dlopen(path.c_str(), kLoadFlags);
  if (handle == nullptr) *error = std::string("dlopen failed: ") + dlerror();
  return handle;
}

void* Symbol(void* handle, const char* name) { return dlsym(handle, name); }

void CloseLibrary(void* handle) { dlclose(handle); }

#endif

}  // namespace

EngineLoader::~EngineLoader() {
  if (handle_ != nullptr) CloseLibrary(handle_);
}

bool EngineLoader::Load(const std::string& engine_dir, std::string* error) {
  const std::string path = engine_dir + "/" + kEngineLibrary;
  handle_ = OpenLibrary(path, error);
  if (handle_ == nullptr) return false;
  using GetProcAddressesFn = FlutterEngineResult (*)(FlutterEngineProcTable*);
  auto get_procs = reinterpret_cast<GetProcAddressesFn>(
      Symbol(handle_, "FlutterEngineGetProcAddresses"));
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
