#include "platform_task_runner.h"

namespace raccoon {

PlatformTaskRunner::PlatformTaskRunner(const FlutterEngineProcTable& procs)
    : procs_(procs), thread_(std::this_thread::get_id()) {
  description_.struct_size = sizeof(FlutterTaskRunnerDescription);
  description_.user_data = this;
  description_.identifier = 1;
  description_.runs_task_on_current_thread_callback = [](void* user_data) {
    return static_cast<PlatformTaskRunner*>(user_data)->RunsOnCurrentThread();
  };
  description_.post_task_callback = [](FlutterTask task, uint64_t target_time,
                                       void* user_data) {
    static_cast<PlatformTaskRunner*>(user_data)->Post(task, target_time);
  };
}

bool PlatformTaskRunner::RunsOnCurrentThread() const {
  return std::this_thread::get_id() == thread_;
}

void PlatformTaskRunner::Post(FlutterTask task, uint64_t target_time) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.push({target_time, task});
  }
  if (wake_) wake_();
}

void PlatformTaskRunner::RunDueTasks() {
  while (true) {
    FlutterTask task;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (queue_.empty() ||
          queue_.top().target_time > procs_.GetCurrentTime()) {
        return;
      }
      task = queue_.top().task;
      queue_.pop();
    }
    if (engine_ != nullptr) procs_.RunTask(engine_, &task);
  }
}

int PlatformTaskRunner::MillisUntilNextTask() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (queue_.empty()) return -1;
  const uint64_t now = procs_.GetCurrentTime();
  const uint64_t target = queue_.top().target_time;
  if (target <= now) return 0;
  const uint64_t millis = (target - now + 999999) / 1000000;
  return millis > 1000 ? 1000 : static_cast<int>(millis);
}

}  // namespace raccoon
