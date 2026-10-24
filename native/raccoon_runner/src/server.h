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
    // Set for a client that does not speak protobuf: every framed message
    // comes here as bytes, with the descriptors received so far, which the
    // handler takes from the front of |fds| (what it leaves is kept for the
    // next message).
    std::function<void(const uint8_t* payload, size_t size, std::vector<int>& fds)>
        on_raw;
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
  // Sends |payload| framed like a message, with the descriptors riding on
  // its first bytes: for a client that does not speak protobuf.
  bool SendBytesWithFds(const std::vector<uint8_t>& payload,
                        const std::vector<int>& fds);

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
  // Keeps a newcomer told the runner is busy until it hangs up, reading and
  // dropping what it sends (see server.cc); Unlinger lets one go.
  void Linger(int fd);
  void Unlinger(int fd);

  EventLoop& loop_;
  Handler handler_;
  std::string socket_path_;
  int listen_fd_ = -1;
  int client_fd_ = -1;
  uint32_t client_pid_ = 0;
  bool closing_ = false;
  static bool WriteAllTo(int fd, const uint8_t* data, size_t size);
  std::vector<uint8_t> inbox_;
  // Where DispatchInbox is in inbox_: past each message before its handler
  // runs, so a handler that closes the client, which dispatches what is
  // left, starts after it, not again from the first (#138).
  size_t inbox_read_ = 0;
  // Descriptors a raw client sent, not yet taken by the handler.
  std::vector<int> fds_in_;
  // Newcomers told the runner is busy, oldest first; a few at most.
  std::vector<int> lingering_;
  static constexpr size_t kMaxLingering = 4;
};

}  // namespace raccoon
