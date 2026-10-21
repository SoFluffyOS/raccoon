#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "event_loop.h"
#include "raccoon/v1/runner.pb.h"

namespace raccoon {

// Serves one client over a Unix socket with length-prefixed protobuf
// messages. Not thread-safe: everything runs on the loop's thread.
class RunnerServer {
 public:
  struct Handler {
    std::function<void(const v1::ClientHello&)> on_hello;
    std::function<void(const v1::ReleaseBuffer&)> on_release_buffer;
    std::function<void(const v1::Resize&)> on_resize;
    std::function<void(const v1::PointerEvent&)> on_pointer;
    std::function<void(const v1::KeyEvent&)> on_key;
    std::function<void(const v1::TextEditing&)> on_text_editing;
    std::function<void()> on_shutdown;
    std::function<void(const v1::PlatformResponse&)> on_platform_response;
    std::function<void()> on_client_connected;
    std::function<void()> on_client_disconnected;
  };

  RunnerServer(EventLoop& loop, Handler handler);
  ~RunnerServer();
  RunnerServer(const RunnerServer&) = delete;
  RunnerServer& operator=(const RunnerServer&) = delete;

  bool Listen(const std::string& socket_path, std::string* error);

  bool has_client() const { return client_fd_ >= 0; }

  // Sends |message| to the client. Returns false when there is no client or
  // it went away.
  bool Send(const v1::RunnerMessage& message);

  // Sends |message| with |fds| attached as ancillary data (SCM_RIGHTS).
  bool SendWithFds(const v1::RunnerMessage& message, const std::vector<int>& fds);

 private:
  void OnListenReadable();
  void OnClientReadable(short revents);
  void CloseClient();
  // Parses and dispatches every whole message in the inbox.
  void DispatchInbox();
  // Reads what the client sent until there is nothing more right now.
  // Returns true when the client hung up or the socket failed.
  bool ReadAvailable();
  bool WriteAll(const uint8_t* data, size_t size);
  void Dispatch(const v1::ClientMessage& message);

  EventLoop& loop_;
  Handler handler_;
  std::string socket_path_;
  int listen_fd_ = -1;
  int client_fd_ = -1;
  uint32_t client_pid_ = 0;
  bool closing_ = false;
  static bool WriteAllTo(int fd, const uint8_t* data, size_t size);
  std::vector<uint8_t> inbox_;
};

}  // namespace raccoon
