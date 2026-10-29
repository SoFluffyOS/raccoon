#pragma once

#include <chrono>
#include <cstdint>
#include <deque>
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
    std::function<void(const v1::Settings&)> on_settings;
    std::function<void(const v1::AppMessage&)> on_app_message;
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
    // Set for a listener whose every connection is a client of its own
    // (the views socket, #182): each accepted socket comes here, for a
    // server of its own to Adopt, and this one never has a client.
    std::function<void(int fd)> on_accept;
  };

  RunnerServer(EventLoop& loop, Handler handler);
  ~RunnerServer();
  RunnerServer(const RunnerServer&) = delete;
  RunnerServer& operator=(const RunnerServer&) = delete;

  bool Listen(const std::string& socket_path, std::string* error);
  // Takes |fd|, a connection accepted elsewhere, as this server's client.
  void Adopt(int fd);
  // Closes |fd|, a connection no server took.
  static void Refuse(int fd);

  bool has_client() const { return client_fd_ >= 0; }
  // Bytes queued for the client and not yet written: frames wait while
  // there are any, the newest replacing the rest.
  size_t backlog() const { return backlog_; }
  // Lets the client go, as when it hangs up.
  void Disconnect() { CloseClient(); }
  // Writes what is queued, waiting for the client up to |timeout_ms|: for
  // the last messages before the runner exits.
  void Drain(int timeout_ms);

  // Queues |message| for the client and writes what the socket takes now;
  // the rest goes as it drains, never blocking the loop (#144). Returns
  // false when there is no client or it went away.
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
  // Queues |bytes|, a framed message, with |fds| (the server's own, closed
  // once sent) riding on its first byte, then writes what it can.
  bool Enqueue(std::string bytes, std::vector<int> fds);
  // Writes the queue until the socket takes no more; then the client's
  // watch asks to hear when it does.
  void Flush();
  void WatchClient();
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
  // The client holds a run it doesn't own (ClientHello.yields): a newcomer
  // that claims it takes it over.
  bool client_yields_ = false;
  // A newcomer while a yielding client holds the runner, waiting for its
  // hello, and what it sent so far (raccoon#281).
  int pending_fd_ = -1;
  std::vector<uint8_t> pending_inbox_;
  // When the pending newcomer came: one silent past kPendingWait gives its
  // place to the next.
  std::chrono::steady_clock::time_point pending_since_;
  static constexpr std::chrono::milliseconds kPendingWait{1000};
  void OnPendingReadable();
  void DropPending();
  void SendBusy(int fd);
  bool closing_ = false;
  static bool WriteAllTo(int fd, const uint8_t* data, size_t size);
  std::vector<uint8_t> inbox_;
  // Where DispatchInbox is in inbox_: past each message before its handler
  // runs, so a handler that closes the client, which dispatches what is
  // left, starts after it, not again from the first (#138).
  size_t inbox_read_ = 0;
  // What waits to be written, the front partly written; descriptors go
  // with a message's first byte. A client that leaves more than
  // kMaxBacklog unread has stopped, and is let go.
  struct Outgoing {
    std::string bytes;
    std::vector<int> fds;
  };
  std::deque<Outgoing> outbox_;
  size_t outbox_sent_ = 0;
  size_t backlog_ = 0;
  bool watching_writable_ = false;
  static constexpr size_t kMaxBacklog = size_t{16} << 20;
  // Descriptors a raw client sent, not yet taken by the handler.
  std::vector<int> fds_in_;
  // Newcomers told the runner is busy, oldest first; a few at most.
  std::vector<int> lingering_;
  static constexpr size_t kMaxLingering = 4;
};

}  // namespace raccoon
