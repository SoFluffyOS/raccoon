#include "stderr_capture.h"

#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <cstdio>

namespace raccoon {

namespace {

// For the crash handler, which may only touch descriptors.
volatile int g_read_fd = -1;
volatile int g_saved_fd = -1;

constexpr int kCrashSignals[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE};
constexpr size_t kLongestLine = 64 * 1024;

void WriteAll(int fd, const char* data, size_t size) {
  while (size > 0) {
    const ssize_t written = write(fd, data, size);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return;
    data += written;
    size -= static_cast<size_t>(written);
  }
}

// Copies what the pipe still holds to the real stderr, then lets the
// signal do what it would have done. Only async-signal-safe calls.
void OnCrash(int signal) {
  const int from = g_read_fd;
  const int to = g_saved_fd;
  if (from >= 0 && to >= 0) {
    char buffer[4096];
    pollfd ready = {from, POLLIN, 0};
    while (poll(&ready, 1, 0) > 0 && (ready.revents & POLLIN)) {
      const ssize_t got = read(from, buffer, sizeof(buffer));
      if (got <= 0) break;
      WriteAll(to, buffer, static_cast<size_t>(got));
    }
  }
  raise(signal);
}

}  // namespace

StderrCapture::~StderrCapture() { Stop(); }

bool StderrCapture::Start(LineCallback on_line) {
  if (thread_.joinable()) return true;
  int fds[2] = {-1, -1};
  int stop[2] = {-1, -1};
  if (pipe(fds) != 0) return false;
  if (pipe(stop) != 0) {
    close(fds[0]);
    close(fds[1]);
    return false;
  }
  std::fflush(stderr);
  const int saved = dup(STDERR_FILENO);
  if (saved < 0 || dup2(fds[1], STDERR_FILENO) < 0) {
    if (saved >= 0) close(saved);
    for (const int fd : {fds[0], fds[1], stop[0], stop[1]}) close(fd);
    return false;
  }
  close(fds[1]);
  // Programs the app starts keep the real stderr's pipe out of their hands.
  for (const int fd : {fds[0], saved, stop[0], stop[1]}) {
    fcntl(fd, F_SETFD, FD_CLOEXEC);
  }
  on_line_ = std::move(on_line);
  read_fd_ = fds[0];
  saved_fd_ = saved;
  stop_read_fd_ = stop[0];
  stop_write_fd_ = stop[1];
  g_read_fd = read_fd_;
  g_saved_fd = saved_fd_;
  for (const int signal : kCrashSignals) {
    struct sigaction action = {};
    action.sa_handler = OnCrash;
    action.sa_flags = SA_RESETHAND | SA_NODEFER;
    sigemptyset(&action.sa_mask);
    sigaction(signal, &action, nullptr);
  }
  thread_ = std::thread([this] { Run(); });
  return true;
}

void StderrCapture::Stop() {
  if (!thread_.joinable()) return;
  std::fflush(stderr);
  // Descriptor 2 is the real stderr again; the thread copies what is left
  // in the pipe and ends. A program the app started may hold the pipe's
  // other end, so the thread is told to stop rather than waiting for it.
  dup2(saved_fd_, STDERR_FILENO);
  const char stop = 1;
  WriteAll(stop_write_fd_, &stop, 1);
  thread_.join();
  for (const int signal : kCrashSignals) std::signal(signal, SIG_DFL);
  g_read_fd = -1;
  g_saved_fd = -1;
  for (const int fd : {read_fd_, saved_fd_, stop_read_fd_, stop_write_fd_}) {
    close(fd);
  }
  read_fd_ = saved_fd_ = stop_read_fd_ = stop_write_fd_ = -1;
}

void StderrCapture::Run() {
  for (;;) {
    pollfd fds[2] = {{read_fd_, POLLIN, 0}, {stop_read_fd_, POLLIN, 0}};
    if (poll(fds, 2, -1) < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (fds[0].revents & (POLLIN | POLLHUP)) {
      if (!Pump(read_fd_)) break;
      continue;
    }
    if (fds[1].revents & POLLIN) {
      // Stopping: what is still in the pipe, without waiting for more.
      fcntl(read_fd_, F_SETFL, fcntl(read_fd_, F_GETFL) | O_NONBLOCK);
      while (Pump(read_fd_)) {
      }
      break;
    }
  }
  if (!partial_.empty() && on_line_) on_line_(partial_);
  partial_.clear();
}

bool StderrCapture::Pump(int fd) {
  char buffer[4096];
  const ssize_t got = read(fd, buffer, sizeof(buffer));
  if (got < 0 && errno == EINTR) return true;
  if (got <= 0) return false;
  WriteAll(saved_fd_, buffer, static_cast<size_t>(got));
  partial_.append(buffer, static_cast<size_t>(got));
  size_t start = 0;
  for (size_t end; (end = partial_.find('\n', start)) != std::string::npos;
       start = end + 1) {
    if (on_line_) on_line_(partial_.substr(start, end - start));
  }
  partial_.erase(0, start);
  // A line that never ends goes out in pieces rather than growing for ever.
  if (partial_.size() > kLongestLine) {
    if (on_line_) on_line_(partial_);
    partial_.clear();
  }
  return true;
}

}  // namespace raccoon
