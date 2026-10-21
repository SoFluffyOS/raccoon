#include "event_loop.h"

#include <poll.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include <cstdint>
#include <vector>

namespace raccoon {

EventLoop::EventLoop() { wake_fd_ = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC); }

EventLoop::~EventLoop() {
  if (wake_fd_ >= 0) close(wake_fd_);
}

void EventLoop::Wake() {
  const uint64_t one = 1;
  [[maybe_unused]] const ssize_t written = write(wake_fd_, &one, sizeof(one));
}

void EventLoop::Watch(int fd, short events, Handler handler) {
  watches_[fd] = {events, std::move(handler)};
}

void EventLoop::Unwatch(int fd) { watches_.erase(fd); }

void EventLoop::RunOnce(int timeout_ms) {
  std::vector<pollfd> fds;
  fds.push_back({wake_fd_, POLLIN, 0});
  for (const auto& [fd, watch] : watches_) fds.push_back({fd, watch.first, 0});
  const int ready = poll(fds.data(), fds.size(), timeout_ms);
  if (ready <= 0) return;
  if (fds[0].revents & POLLIN) {
    uint64_t value = 0;
    [[maybe_unused]] const ssize_t got = read(wake_fd_, &value, sizeof(value));
  }
  std::vector<std::pair<Handler, short>> pending;
  for (size_t i = 1; i < fds.size(); ++i) {
    if (fds[i].revents == 0) continue;
    const auto watch = watches_.find(fds[i].fd);
    if (watch != watches_.end()) {
      pending.push_back({watch->second.second, fds[i].revents});
    }
  }
  for (auto& [handler, revents] : pending) handler(revents);
}

}  // namespace raccoon
