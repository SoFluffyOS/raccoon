#pragma once
// The main run loop, turned by the runner's own loop: macOS plugins answer
// from the main dispatch queue, set timers and open panels, all of which
// run on it. While the pump lives the loop waits in the run loop instead of
// poll(2), with its descriptors in a kqueue the run loop watches; AppKit's
// events are handed out after each wait.
//
// A plugin's modal panel or alert runs the run loop in its modal panel
// mode until it closes, which holds the runner's loop. A timer in that mode
// alone, which fires only while a modal loop runs, takes the loop's turns
// meanwhile.
#if RACCOON_HAS_PLUGINS && defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <poll.h>

#include <cstddef>
#include <functional>
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

  // What a turn of the runner's loop is, for while a modal loop holds it:
  // its work, then a look at the descriptors without waiting.
  void SetModalTurn(std::function<void()> turn) { turn_ = std::move(turn); }

 private:
  int Wait(pollfd* fds, size_t count, int timeout_ms);
  // One turn of Wait, inside its autorelease pool.
  int Turn(pollfd* fds, size_t count, int timeout_ms);

  static void OnModalTimer(CFRunLoopTimerRef timer, void* info);

  struct Impl;
  EventLoop& loop_;
  std::unique_ptr<Impl> impl_;
  std::function<void()> turn_;
  // Inside a turn taken from the modal timer: the loop's look at its
  // descriptors must neither run the run loop nor hand out events, which
  // are the modal loop's.
  bool turning_ = false;
};

}  // namespace raccoon
#else
namespace raccoon {
// Without plugins there is nothing to turn; the type stays so main names
// it either way.
class RunLoopPump {};
}  // namespace raccoon
#endif
