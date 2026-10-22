#pragma once
// The runner's stderr, read back as lines while it still reaches the real
// one. The engine prints what the app dies of there (an uncaught exception
// in main() is "Unhandled Exception: ..." on stderr), and so does the
// runner; serve relays the lines to its client, which has no other way to
// see them.
//
// Descriptor 2 becomes a pipe; a thread copies every byte to the original
// stderr as it comes, then hands whole lines to the callback. A crash
// signal copies what is still in the pipe before the process dies, so
// nothing the tool would have shown is lost.

#include <functional>
#include <string>
#include <thread>

namespace raccoon {

class StderrCapture {
 public:
  // Called on the capture's thread, once per line, without its newline.
  using LineCallback = std::function<void(const std::string& line)>;

  StderrCapture() = default;
  ~StderrCapture();
  StderrCapture(const StderrCapture&) = delete;
  StderrCapture& operator=(const StderrCapture&) = delete;

  // False, and stderr untouched, when the pipe or the thread cannot be had.
  bool Start(LineCallback on_line);
  // Gives descriptor 2 back and copies what is left; lines after this go
  // straight to stderr.
  void Stop();

 private:
  void Run();
  // Copies one read's worth to the original stderr and splits it into
  // lines. False at the end of the pipe.
  bool Pump(int fd);

  LineCallback on_line_;
  std::thread thread_;
  std::string partial_;
  int read_fd_ = -1;
  int saved_fd_ = -1;
  int stop_read_fd_ = -1;
  int stop_write_fd_ = -1;
};

}  // namespace raccoon
