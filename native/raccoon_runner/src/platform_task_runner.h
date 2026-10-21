#pragma once

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <queue>
#include <thread>
#include <vector>

#include "flutter_embedder.h"

namespace raccoon {

// The engine's platform task runner, pumped by the thread that created it.
// Tasks are ordered by the engine's target time.
class PlatformTaskRunner {
 public:
  explicit PlatformTaskRunner(const FlutterEngineProcTable& procs);

  // Must be called once FlutterEngineRun returned the engine handle.
  void SetEngine(FLUTTER_API_SYMBOL(FlutterEngine) engine) { engine_ = engine; }

  // The description to hand to FlutterCustomTaskRunners; valid while this
  // object lives.
  const FlutterTaskRunnerDescription& description() const {
    return description_;
  }

  // Runs due tasks and sleeps between them until |done| returns true or
  // |timeout| elapsed.
  void PumpUntil(const std::function<bool()>& done,
                 std::chrono::milliseconds timeout);

  // Runs every task that is due now and returns.
  void RunDueTasks();

 private:
  struct Pending {
    uint64_t target_time;
    FlutterTask task;
    bool operator>(const Pending& other) const {
      return target_time > other.target_time;
    }
  };

  bool RunsOnCurrentThread() const;
  void Post(FlutterTask task, uint64_t target_time);

  const FlutterEngineProcTable& procs_;
  FLUTTER_API_SYMBOL(FlutterEngine) engine_ = nullptr;
  std::thread::id thread_;
  FlutterTaskRunnerDescription description_{};
  std::mutex mutex_;
  std::condition_variable wake_;
  std::priority_queue<Pending, std::vector<Pending>, std::greater<Pending>>
      queue_;
};

}  // namespace raccoon
