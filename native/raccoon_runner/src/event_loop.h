#pragma once

#include <poll.h>

#include <functional>
#include <unordered_map>
#include <utility>
#include <vector>

namespace raccoon {

// A poll loop over watched descriptors plus a wake descriptor that any thread
// can signal.
class EventLoop {
 public:
  using Handler = std::function<void(short revents)>;

  EventLoop();
  ~EventLoop();
  EventLoop(const EventLoop&) = delete;
  EventLoop& operator=(const EventLoop&) = delete;

  // Makes RunOnce return; safe from any thread and from signal handlers.
  void Wake();

  void Watch(int fd, short events, Handler handler);
  void Unwatch(int fd);

  // One poll iteration. A negative |timeout_ms| waits until an event or Wake.
  void RunOnce(int timeout_ms);
  // An outside source that joins every poll: |prepare| appends its
  // descriptors and may shorten |timeout_ms|; |dispatch| sees them back with
  // their revents after the poll, whether or not anything was ready. Null
  // for none. For GLib's main context.
  using Prepare = std::function<void(std::vector<pollfd>& fds, int& timeout_ms)>;
  using Dispatch = std::function<void(const pollfd* fds, size_t count)>;
  void SetExternal(Prepare prepare, Dispatch dispatch) {
    prepare_ = std::move(prepare);
    dispatch_ = std::move(dispatch);
  }
  // Waits on |fds| for up to |timeout_ms| (negative: no limit) and fills in
  // their revents, as poll(2) would, which it replaces; returns how many are
  // ready. Null for poll itself. For macOS, where the main run loop has to
  // turn while the loop waits.
  using Waiter = std::function<int(pollfd* fds, size_t count, int timeout_ms)>;
  void SetWaiter(Waiter waiter) { waiter_ = std::move(waiter); }

 private:
  // The read and write ends of the wake descriptor: one eventfd on Linux, the
  // two ends of a pipe elsewhere.
  int wake_fd_ = -1;
  int wake_write_fd_ = -1;
  std::unordered_map<int, std::pair<short, Handler>> watches_;
  Prepare prepare_;
  Dispatch dispatch_;
  Waiter waiter_;
};

}  // namespace raccoon
