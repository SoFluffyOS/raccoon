#pragma once

#include <string>

#include "flutter_embedder.h"

namespace raccoon {

// Loads libflutter_engine.so from a runtime directory and resolves the
// embedder proc table, so one runner binary can host any engine revision.
class EngineLoader {
 public:
  EngineLoader() = default;
  ~EngineLoader();
  EngineLoader(const EngineLoader&) = delete;
  EngineLoader& operator=(const EngineLoader&) = delete;

  // Returns false and fills |error| when the library or its entry point is
  // missing.
  bool Load(const std::string& engine_dir, std::string* error);

  const FlutterEngineProcTable& procs() const { return procs_; }

 private:
  void* handle_ = nullptr;
  FlutterEngineProcTable procs_{};
};

}  // namespace raccoon
