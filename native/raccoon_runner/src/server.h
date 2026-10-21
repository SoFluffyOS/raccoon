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
    std::function<void(const v1::Resize&)> on_resize;
    std::function<void(const v1::PointerEvent&)> on_pointer;
    std::function<void(const v1::KeyEvent&)> on_key;
    std::function<void()> on_shutdown;
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

 private:
  void OnListenReadable();
  void OnClientReadable(short revents);
  void CloseClient();
  bool WriteAll(const uint8_t* data, size_t size);
  void Dispatch(const v1::ClientMessage& message);

  EventLoop& loop_;
  Handler handler_;
  std::string socket_path_;
  int listen_fd_ = -1;
  int client_fd_ = -1;
  std::vector<uint8_t> inbox_;
};

}  // namespace raccoon
