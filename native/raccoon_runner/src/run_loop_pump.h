#pragma once
// The main run loop, turned by the runner's own loop: macOS plugins answer
// from the main dispatch queue, set timers and open panels, all of which
// run on it. While the pump lives the loop waits in the run loop instead of
// poll(2), with its descriptors in a kqueue the run loop watches; AppKit's
// events are handed out after each wait.
#if RACCOON_HAS_PLUGINS && defined(__APPLE__)
#include <poll.h>

#include <cstddef>
#include <memory>

#include "event_loop.h"

namespace raccoon {

class RunLoopPump {
 public:
  // Hooks |loop|, which must be turned by the main thread.
  explicit RunLoopPump(EventLoop& loop);
  ~RunLoopPump();
  RunLoopPump(const RunLoopPump&) = delete;
  RunLoopPump& operator=(const RunLoopPump&) = delete;

 private:
  int Wait(pollfd* fds, size_t count, int timeout_ms);
  // One turn of Wait, inside its autorelease pool.
  int Turn(pollfd* fds, size_t count, int timeout_ms);

  struct Impl;
  EventLoop& loop_;
  std::unique_ptr<Impl> impl_;
};

}  // namespace raccoon
#else
namespace raccoon {
// Without plugins there is nothing to turn; the type stays so main names
// it either way.
class RunLoopPump {};
}  // namespace raccoon
#endif
