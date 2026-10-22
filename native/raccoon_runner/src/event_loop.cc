#include "event_loop.h"

#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <cstdint>
#include <vector>

#if defined(__linux__)
#include <sys/eventfd.h>
#endif

namespace raccoon {

// Linux wakes the loop through an eventfd. macOS has none, so a pipe does the
// same job: a byte written to wake, every byte drained on the way out.
EventLoop::EventLoop() {
#if defined(__linux__)
  wake_fd_ = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  wake_write_fd_ = wake_fd_;
#else
  int fds[2] = {-1, -1};
  if (pipe(fds) != 0) return;
  for (const int fd : fds) {
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
  }
  wake_fd_ = fds[0];
  wake_write_fd_ = fds[1];
#endif
}

EventLoop::~EventLoop() {
  if (wake_write_fd_ >= 0 && wake_write_fd_ != wake_fd_) close(wake_write_fd_);
  if (wake_fd_ >= 0) close(wake_fd_);
}

void EventLoop::Wake() {
  const uint64_t one = 1;
  [[maybe_unused]] const ssize_t written =
      write(wake_write_fd_, &one, sizeof(one));
}

void EventLoop::Watch(int fd, short events, Handler handler) {
  watches_[fd] = {events, std::move(handler)};
}

void EventLoop::Unwatch(int fd) { watches_.erase(fd); }

void EventLoop::RunOnce(int timeout_ms) {
  std::vector<pollfd> fds;
  fds.push_back({wake_fd_, POLLIN, 0});
  for (const auto& [fd, watch] : watches_) fds.push_back({fd, watch.first, 0});
  const size_t own = fds.size();
  if (prepare_) prepare_(fds, timeout_ms);
  const int ready = poll(fds.data(), fds.size(), timeout_ms);
  if (dispatch_) dispatch_(fds.data() + own, fds.size() - own);
  if (ready <= 0) return;
  if (fds[0].revents & POLLIN) {
    uint64_t pending = 0;
    while (read(wake_fd_, &pending, sizeof(pending)) > 0) {
    }
  }
  std::vector<std::pair<Handler, short>> pending;
  for (size_t i = 1; i < own; ++i) {
    if (fds[i].revents == 0) continue;
    const auto watch = watches_.find(fds[i].fd);
    if (watch != watches_.end()) {
      pending.push_back({watch->second.second, fds[i].revents});
    }
  }
  for (auto& [handler, revents] : pending) handler(revents);
}

}  // namespace raccoon
