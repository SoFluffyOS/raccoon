#pragma once

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

  // Called from any thread whenever a task is posted, so the owner's loop can
  // wake up and pump.
  void SetWakeCallback(std::function<void()> wake) { wake_ = std::move(wake); }

  // The description to hand to FlutterCustomTaskRunners; valid while this
  // object lives.
  const FlutterTaskRunnerDescription& description() const {
    return description_;
  }

  // Runs every task that is due now and returns.
  void RunDueTasks();

  // Milliseconds until the next task is due: 0 when one is due, -1 when the
  // queue is empty.
  int MillisUntilNextTask();

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
  std::function<void()> wake_;
  std::mutex mutex_;
  std::priority_queue<Pending, std::vector<Pending>, std::greater<Pending>>
      queue_;
};

}  // namespace raccoon
