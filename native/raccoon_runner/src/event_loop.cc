#include "event_loop.h"

#include <cstdint>
#include <tuple>
#include <vector>

#if defined(_WIN32)
#include "win_sockets.h"
#else
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#endif

#if defined(__linux__)
#include <sys/eventfd.h>
#endif

namespace raccoon {

namespace {

#if defined(_WIN32)
int Poll(pollfd* fds, size_t count, int timeout_ms) {
  return WSAPoll(fds, static_cast<ULONG>(count), timeout_ms);
}
#else
int Poll(pollfd* fds, size_t count, int timeout_ms) {
  return poll(fds, count, timeout_ms);
}
#endif

}  // namespace

// Linux wakes the loop through an eventfd. macOS has none, so a pipe does the
// same job: a byte written to wake, every byte drained on the way out. On
// Windows the pipe is a pair of sockets.
EventLoop::EventLoop() {
#if defined(__linux__)
  wake_fd_ = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  wake_write_fd_ = wake_fd_;
#elif defined(_WIN32)
  int fds[2] = {-1, -1};
  if (!SocketPair(fds)) return;
  wake_fd_ = fds[0];
  wake_write_fd_ = fds[1];
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

#if defined(_WIN32)

EventLoop::~EventLoop() {
  CloseSocket(wake_write_fd_);
  CloseSocket(wake_fd_);
}

void EventLoop::Wake() {
  const char one = 1;
  send(AsSocket(wake_write_fd_), &one, 1, 0);
}

namespace {

void DrainWake(int fd) {
  char pending[64];
  while (recv(AsSocket(fd), pending, sizeof(pending), 0) > 0) {
  }
}

}  // namespace

#else

EventLoop::~EventLoop() {
  if (wake_write_fd_ >= 0 && wake_write_fd_ != wake_fd_) close(wake_write_fd_);
  if (wake_fd_ >= 0) close(wake_fd_);
}

void EventLoop::Wake() {
  const uint64_t one = 1;
  [[maybe_unused]] const ssize_t written =
      write(wake_write_fd_, &one, sizeof(one));
}

namespace {

void DrainWake(int fd) {
  uint64_t pending = 0;
  while (read(fd, &pending, sizeof(pending)) > 0) {
  }
}

}  // namespace

#endif

void EventLoop::Watch(int fd, short events, Handler handler) {
  watches_[fd] = {events, std::move(handler)};
}

void EventLoop::Unwatch(int fd) { watches_.erase(fd); }

void EventLoop::RunOnce(int timeout_ms) {
  std::vector<pollfd> fds;
  fds.push_back(PollEntry(wake_fd_, POLLIN));
  for (const auto& [fd, watch] : watches_) fds.push_back(PollEntry(fd, watch.first));
  const size_t own = fds.size();
  if (prepare_) prepare_(fds, timeout_ms);
  const int ready = waiter_ ? waiter_(fds.data(), fds.size(), timeout_ms)
                           : Poll(fds.data(), fds.size(), timeout_ms);
  if (dispatch_) dispatch_(fds.data() + own, fds.size() - own);
  if (ready <= 0) return;
  if (fds[0].revents & POLLIN) DrainWake(wake_fd_);
  std::vector<std::tuple<int, Handler, short>> pending;
  for (size_t i = 1; i < own; ++i) {
    if (fds[i].revents == 0) continue;
    const int fd = static_cast<int>(fds[i].fd);
    const auto watch = watches_.find(fd);
    if (watch != watches_.end()) {
      pending.emplace_back(fd, watch->second.second, fds[i].revents);
    }
  }
  // A handler can close another's descriptor (a listen dropping the oldest
  // lingering newcomer): that one no longer runs (#138).
  for (auto& [fd, handler, revents] : pending) {
    if (watches_.count(fd) != 0) handler(revents);
  }
}

}  // namespace raccoon
