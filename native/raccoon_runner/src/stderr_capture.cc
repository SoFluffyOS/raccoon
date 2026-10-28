#include "stderr_capture.h"

#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#else
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#endif

#include <cerrno>
#include <csignal>
#include <cstdio>

namespace raccoon {

namespace {

// For the crash handler, which may only touch descriptors.
volatile int g_read_fd = -1;
volatile int g_saved_fd = -1;

#if defined(_WIN32)
// No SIGBUS on Windows; the C runtime raises SIGSEGV for an access violation
// when a handler is installed.
constexpr int kCrashSignals[] = {SIGSEGV, SIGABRT, SIGILL, SIGFPE};
constexpr int kStderr = 2;
using ReadResult = int;
#else
constexpr int kCrashSignals[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE};
constexpr int kStderr = STDERR_FILENO;
using ReadResult = ssize_t;
#endif
constexpr size_t kLongestLine = 64 * 1024;
// Reads of 4 KB taken from the pipe once stopping: more than a pipe holds,
// and a bound for a child that inherited stderr and keeps writing.
constexpr int kDrainReads = 64;

#if defined(_WIN32)
ReadResult ReadFd(int fd, char* buffer, size_t size) {
  return _read(fd, buffer, static_cast<unsigned>(size));
}
int WriteFd(int fd, const char* data, size_t size) {
  return _write(fd, data, static_cast<unsigned>(size));
}
// Whether the pipe behind |fd| holds bytes now, without waiting.
bool Pending(int fd) {
  DWORD available = 0;
  const auto pipe = reinterpret_cast<HANDLE>(_get_osfhandle(fd));
  return PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr) && available > 0;
}
#else
ReadResult ReadFd(int fd, char* buffer, size_t size) { return read(fd, buffer, size); }
ReadResult WriteFd(int fd, const char* data, size_t size) { return write(fd, data, size); }
bool Pending(int fd) {
  pollfd ready = {fd, POLLIN, 0};
  return poll(&ready, 1, 0) > 0 && (ready.revents & POLLIN);
}
#endif

void WriteAll(int fd, const char* data, size_t size) {
  while (size > 0) {
    const auto written = WriteFd(fd, data, size);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return;
    data += written;
    size -= static_cast<size_t>(written);
  }
}

// Copies what the pipe still holds to the real stderr, then lets the
// signal do what it would have done (Windows resets the handler before
// calling it, as SA_RESETHAND does). Only async-signal-safe calls.
void OnCrash(int signal) {
  const int from = g_read_fd;
  const int to = g_saved_fd;
  if (from >= 0 && to >= 0) {
#if !defined(_WIN32)
    // The reader thread may take what Pending saw first, and a blocking
    // read would then wait for good: the pipe's other end is stderr itself
    // (raccoon#235).
    fcntl(from, F_SETFL, fcntl(from, F_GETFL) | O_NONBLOCK);
#endif
    char buffer[4096];
    while (Pending(from)) {
      const auto got = ReadFd(from, buffer, sizeof(buffer));
      if (got <= 0) break;
      WriteAll(to, buffer, static_cast<size_t>(got));
    }
  }
  raise(signal);
}

void InstallCrashHandlers() {
  for (const int signal : kCrashSignals) {
#if defined(_WIN32)
    std::signal(signal, OnCrash);
#else
    struct sigaction action = {};
    action.sa_handler = OnCrash;
    action.sa_flags = SA_RESETHAND | SA_NODEFER;
    sigemptyset(&action.sa_mask);
    sigaction(signal, &action, nullptr);
#endif
  }
}

// A pipe whose ends the programs the app starts do not get.
bool OpenPipe(int fds[2]) {
#if defined(_WIN32)
  return _pipe(fds, 64 * 1024, _O_BINARY | _O_NOINHERIT) == 0;
#else
  if (pipe(fds) != 0) return false;
  for (int i = 0; i < 2; ++i) fcntl(fds[i], F_SETFD, FD_CLOEXEC);
  return true;
#endif
}

void CloseFd(int fd) {
#if defined(_WIN32)
  _close(fd);
#else
  close(fd);
#endif
}

}  // namespace

StderrCapture::~StderrCapture() { Stop(); }

bool StderrCapture::Start(LineCallback on_line) {
  if (thread_.joinable()) return true;
  int fds[2] = {-1, -1};
  int stop[2] = {-1, -1};
  if (!OpenPipe(fds)) return false;
  if (!OpenPipe(stop)) {
    CloseFd(fds[0]);
    CloseFd(fds[1]);
    return false;
  }
  std::fflush(stderr);
#if defined(_WIN32)
  const int saved = _dup(kStderr);
  // A process started without a console has no stderr to save; the lines
  // then go to the client alone.
  if (saved >= 0) {
    const auto handle = reinterpret_cast<HANDLE>(_get_osfhandle(saved));
    SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0);
  }
  if (_dup2(fds[1], kStderr) < 0) {
#else
  const int saved = dup(kStderr);
  if (saved < 0 || dup2(fds[1], kStderr) < 0) {
#endif
    if (saved >= 0) CloseFd(saved);
    for (const int fd : {fds[0], fds[1], stop[0], stop[1]}) CloseFd(fd);
    return false;
  }
  CloseFd(fds[1]);
#if !defined(_WIN32)
  // Programs the app starts keep the real stderr's pipe out of their hands.
  fcntl(saved, F_SETFD, FD_CLOEXEC);
#endif
  on_line_ = std::move(on_line);
  read_fd_ = fds[0];
  saved_fd_ = saved;
  stop_read_fd_ = stop[0];
  stop_write_fd_ = stop[1];
  g_read_fd = read_fd_;
  g_saved_fd = saved_fd_;
  InstallCrashHandlers();
  thread_ = std::thread([this] { Run(); });
  return true;
}

void StderrCapture::Stop() {
  if (!thread_.joinable()) return;
  std::fflush(stderr);
  // Descriptor 2 is the real stderr again; the thread copies what is left
  // in the pipe and ends. A program the app started may hold the pipe's
  // other end, so the thread is told to stop rather than waiting for it.
#if defined(_WIN32)
  if (saved_fd_ >= 0) _dup2(saved_fd_, kStderr);
  // No poll on a pipe here: the thread sits in a read, which is cancelled
  // until it notices.
  stopping_ = true;
  while (!finished_) {
    CancelSynchronousIo(reinterpret_cast<HANDLE>(thread_.native_handle()));
    Sleep(1);
  }
#else
  dup2(saved_fd_, kStderr);
  const char stop = 1;
  WriteAll(stop_write_fd_, &stop, 1);
#endif
  thread_.join();
  for (const int signal : kCrashSignals) std::signal(signal, SIG_DFL);
  g_read_fd = -1;
  g_saved_fd = -1;
  for (const int fd : {read_fd_, saved_fd_, stop_read_fd_, stop_write_fd_}) {
    if (fd >= 0) CloseFd(fd);
  }
  read_fd_ = saved_fd_ = stop_read_fd_ = stop_write_fd_ = -1;
}

#if defined(_WIN32)

void StderrCapture::Run() {
  while (!stopping_ && Pump(read_fd_)) {
  }
  // Stopping: what is still in the pipe, without waiting for more.
  for (int i = 0; i < kDrainReads && Pending(read_fd_) && Pump(read_fd_); ++i) {
  }
  if (!partial_.empty() && on_line_) on_line_(partial_);
  partial_.clear();
  finished_ = true;
}

#else

void StderrCapture::Run() {
  for (;;) {
    pollfd fds[2] = {{read_fd_, POLLIN, 0}, {stop_read_fd_, POLLIN, 0}};
    if (poll(fds, 2, -1) < 0) {
      if (errno == EINTR) continue;
      break;
    }
    // The stop first: a pipe that never runs dry must not hold it up.
    if (fds[1].revents & POLLIN) {
      // Stopping: what is still in the pipe, without waiting for more.
      fcntl(read_fd_, F_SETFL, fcntl(read_fd_, F_GETFL) | O_NONBLOCK);
      for (int i = 0; i < kDrainReads && Pump(read_fd_); ++i) {
      }
      break;
    }
    if ((fds[0].revents & (POLLIN | POLLHUP)) && !Pump(read_fd_)) break;
  }
  if (!partial_.empty() && on_line_) on_line_(partial_);
  partial_.clear();
}

#endif

bool StderrCapture::Pump(int fd) {
  char buffer[4096];
  const auto got = ReadFd(fd, buffer, sizeof(buffer));
  if (got < 0 && errno == EINTR) return true;
  if (got <= 0) return false;
  if (saved_fd_ >= 0) WriteAll(saved_fd_, buffer, static_cast<size_t>(got));
  partial_.append(buffer, static_cast<size_t>(got));
  size_t start = 0;
  for (size_t end; (end = partial_.find('\n', start)) != std::string::npos;
       start = end + 1) {
    // Windows' C runtime ends stderr's lines with CRLF.
    const size_t stop = end > start && partial_[end - 1] == '\r' ? end - 1 : end;
    if (on_line_) on_line_(partial_.substr(start, stop - start));
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
