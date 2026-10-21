#include "platform_task_runner.h"

#include <algorithm>

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
  wake_.notify_one();
}

void PlatformTaskRunner::RunDueTasks() {
  while (true) {
    FlutterTask task;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (queue_.empty() || queue_.top().target_time > procs_.GetCurrentTime()) {
        return;
      }
      task = queue_.top().task;
      queue_.pop();
    }
    if (engine_ != nullptr) procs_.RunTask(engine_, &task);
  }
}

void PlatformTaskRunner::PumpUntil(const std::function<bool()>& done,
                                   std::chrono::milliseconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (true) {
    RunDueTasks();
    if (done()) return;
    const auto now = std::chrono::steady_clock::now();
    if (now >= deadline) return;
    auto wait_until = std::min(deadline, now + std::chrono::milliseconds(20));
    std::unique_lock<std::mutex> lock(mutex_);
    if (!queue_.empty()) {
      const uint64_t due_in = queue_.top().target_time - procs_.GetCurrentTime();
      const auto next_due = now + std::chrono::nanoseconds(
          queue_.top().target_time > procs_.GetCurrentTime() ? due_in : 0);
      wait_until = std::min(wait_until, next_due);
    }
    wake_.wait_until(lock, wait_until);
  }
}

}  // namespace raccoon
