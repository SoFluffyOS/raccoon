#include "server.h"

#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>

namespace raccoon {

namespace {

constexpr size_t kLengthPrefix = 4;
constexpr size_t kMaxMessage = 64 * 1024 * 1024;

uint32_t ReadLength(const uint8_t* data) {
  return static_cast<uint32_t>(data[0]) | (static_cast<uint32_t>(data[1]) << 8) |
         (static_cast<uint32_t>(data[2]) << 16) |
         (static_cast<uint32_t>(data[3]) << 24);
}

}  // namespace

RunnerServer::RunnerServer(EventLoop& loop, Handler handler)
    : loop_(loop), handler_(std::move(handler)) {}

RunnerServer::~RunnerServer() {
  CloseClient();
  if (listen_fd_ >= 0) {
    loop_.Unwatch(listen_fd_);
    close(listen_fd_);
    unlink(socket_path_.c_str());
  }
}

bool RunnerServer::Listen(const std::string& socket_path, std::string* error) {
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (socket_path.size() >= sizeof(address.sun_path)) {
    *error = "socket path too long: " + socket_path;
    return false;
  }
  std::strncpy(address.sun_path, socket_path.c_str(),
               sizeof(address.sun_path) - 1);

  listen_fd_ = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (listen_fd_ < 0) {
    *error = std::string("socket: ") + std::strerror(errno);
    return false;
  }
  unlink(socket_path.c_str());
  if (bind(listen_fd_, reinterpret_cast<sockaddr*>(&address),
           sizeof(address)) < 0) {
    *error = std::string("bind: ") + std::strerror(errno);
    return false;
  }
  if (listen(listen_fd_, 1) < 0) {
    *error = std::string("listen: ") + std::strerror(errno);
    return false;
  }
  socket_path_ = socket_path;
  loop_.Watch(listen_fd_, POLLIN, [this](short) { OnListenReadable(); });
  return true;
}

void RunnerServer::OnListenReadable() {
  const int fd = accept4(listen_fd_, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
  if (fd < 0) return;
  if (client_fd_ >= 0) {
    close(fd);
    return;
  }
  client_fd_ = fd;
  inbox_.clear();
  loop_.Watch(client_fd_, POLLIN,
              [this](short revents) { OnClientReadable(revents); });
  if (handler_.on_client_connected) handler_.on_client_connected();
}

void RunnerServer::OnClientReadable(short revents) {
  if (revents & (POLLHUP | POLLERR | POLLNVAL)) {
    CloseClient();
    return;
  }
  uint8_t buffer[64 * 1024];
  while (true) {
    const ssize_t got = read(client_fd_, buffer, sizeof(buffer));
    if (got > 0) {
      inbox_.insert(inbox_.end(), buffer, buffer + got);
      continue;
    }
    if (got == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) {
      CloseClient();
      return;
    }
    break;
  }
  size_t offset = 0;
  while (inbox_.size() - offset >= kLengthPrefix) {
    const uint32_t length = ReadLength(inbox_.data() + offset);
    if (length > kMaxMessage) {
      CloseClient();
      return;
    }
    if (inbox_.size() - offset - kLengthPrefix < length) break;
    v1::ClientMessage message;
    if (message.ParseFromArray(inbox_.data() + offset + kLengthPrefix,
                               static_cast<int>(length))) {
      Dispatch(message);
    }
    offset += kLengthPrefix + length;
    if (client_fd_ < 0) return;
  }
  inbox_.erase(inbox_.begin(), inbox_.begin() + offset);
}

void RunnerServer::Dispatch(const v1::ClientMessage& message) {
  switch (message.message_case()) {
    case v1::ClientMessage::kHello:
      break;
    case v1::ClientMessage::kResize:
      if (handler_.on_resize) handler_.on_resize(message.resize());
      break;
    case v1::ClientMessage::kPointer:
      if (handler_.on_pointer) handler_.on_pointer(message.pointer());
      break;
    case v1::ClientMessage::kKey:
      if (handler_.on_key) handler_.on_key(message.key());
      break;
    case v1::ClientMessage::kShutdown:
      if (handler_.on_shutdown) handler_.on_shutdown();
      break;
    case v1::ClientMessage::MESSAGE_NOT_SET:
      break;
  }
}

void RunnerServer::CloseClient() {
  if (client_fd_ < 0) return;
  loop_.Unwatch(client_fd_);
  close(client_fd_);
  client_fd_ = -1;
  inbox_.clear();
  if (handler_.on_client_disconnected) handler_.on_client_disconnected();
}

bool RunnerServer::WriteAll(const uint8_t* data, size_t size) {
  size_t sent = 0;
  while (sent < size) {
    const ssize_t wrote =
        send(client_fd_, data + sent, size - sent, MSG_NOSIGNAL);
    if (wrote >= 0) {
      sent += static_cast<size_t>(wrote);
      continue;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      pollfd wait{client_fd_, POLLOUT, 0};
      if (poll(&wait, 1, 5000) <= 0) return false;
      continue;
    }
    return false;
  }
  return true;
}

bool RunnerServer::Send(const v1::RunnerMessage& message) {
  if (client_fd_ < 0) return false;
  std::string payload;
  if (!message.SerializeToString(&payload)) return false;
  const uint32_t length = static_cast<uint32_t>(payload.size());
  const uint8_t prefix[kLengthPrefix] = {
      static_cast<uint8_t>(length), static_cast<uint8_t>(length >> 8),
      static_cast<uint8_t>(length >> 16), static_cast<uint8_t>(length >> 24)};
  if (!WriteAll(prefix, kLengthPrefix) ||
      !WriteAll(reinterpret_cast<const uint8_t*>(payload.data()),
                payload.size())) {
    CloseClient();
    return false;
  }
  return true;
}

}  // namespace raccoon
