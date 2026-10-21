#include "server.h"

#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>

namespace raccoon {

namespace {

constexpr size_t kLengthPrefix = 4;
constexpr size_t kMaxMessage = 64 * 1024 * 1024;

// Sockets are non-blocking and close-on-exec, and a client that went away
// must fail a send with EPIPE rather than raise SIGPIPE. Linux asks for all of
// it in the calls themselves; macOS sets the flags afterwards and silences
// SIGPIPE per socket.
#if defined(__linux__)

constexpr int kSendFlags = MSG_NOSIGNAL;

int OpenListenSocket() {
  return socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
}

int AcceptClient(int listen_fd) {
  return accept4(listen_fd, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
}

#else

constexpr int kSendFlags = 0;

bool SetNonBlockingCloseOnExec(int fd) {
  return fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 &&
         fcntl(fd, F_SETFD, FD_CLOEXEC) == 0;
}

int OpenListenSocket() {
  const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return fd;
  if (!SetNonBlockingCloseOnExec(fd)) {
    close(fd);
    return -1;
  }
  return fd;
}

int AcceptClient(int listen_fd) {
  const int fd = accept(listen_fd, nullptr, nullptr);
  if (fd < 0) return fd;
  const int no_sigpipe = 1;
  if (!SetNonBlockingCloseOnExec(fd) ||
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe,
                 sizeof(no_sigpipe)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

#endif

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

  listen_fd_ = OpenListenSocket();
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
  const int fd = AcceptClient(listen_fd_);
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
  // A hang-up often arrives together with the last bytes, so drain first: a
  // message sent right before the client closed is still dispatched.
  uint8_t buffer[64 * 1024];
  bool closed = (revents & (POLLERR | POLLNVAL)) != 0;
  while (true) {
    const ssize_t got = read(client_fd_, buffer, sizeof(buffer));
    if (got > 0) {
      inbox_.insert(inbox_.end(), buffer, buffer + got);
      continue;
    }
    closed = got == 0 || (errno != EAGAIN && errno != EWOULDBLOCK);
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
  if (closed) CloseClient();
}

void RunnerServer::Dispatch(const v1::ClientMessage& message) {
  switch (message.message_case()) {
    case v1::ClientMessage::kHello:
      if (handler_.on_hello) handler_.on_hello(message.hello());
      break;
    case v1::ClientMessage::kReleaseBuffer:
      if (handler_.on_release_buffer) {
        handler_.on_release_buffer(message.release_buffer());
      }
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
    case v1::ClientMessage::kPlatformResponse:
      if (handler_.on_platform_response) {
        handler_.on_platform_response(message.platform_response());
      }
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
        send(client_fd_, data + sent, size - sent, kSendFlags);
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

bool RunnerServer::SendWithFds(const v1::RunnerMessage& message,
                               const std::vector<int>& fds) {
  if (client_fd_ < 0) return false;
  std::string payload;
  if (!message.SerializeToString(&payload)) return false;
  const uint32_t length = static_cast<uint32_t>(payload.size());
  uint8_t prefix[kLengthPrefix] = {
      static_cast<uint8_t>(length), static_cast<uint8_t>(length >> 8),
      static_cast<uint8_t>(length >> 16), static_cast<uint8_t>(length >> 24)};
  iovec parts[2] = {{prefix, kLengthPrefix},
                    {payload.data(), payload.size()}};
  std::vector<uint8_t> control(CMSG_SPACE(sizeof(int) * fds.size()));
  msghdr header{};
  header.msg_iov = parts;
  header.msg_iovlen = 2;
  header.msg_control = control.data();
  header.msg_controllen = control.size();
  cmsghdr* cmsg = CMSG_FIRSTHDR(&header);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(sizeof(int) * fds.size());
  std::memcpy(CMSG_DATA(cmsg), fds.data(), sizeof(int) * fds.size());
  ssize_t sent;
  while (true) {
    sent = sendmsg(client_fd_, &header, kSendFlags);
    if (sent >= 0) break;
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      pollfd wait{client_fd_, POLLOUT, 0};
      if (poll(&wait, 1, 5000) <= 0) {
        CloseClient();
        return false;
      }
      continue;
    }
    CloseClient();
    return false;
  }
  // The descriptors travelled with the first bytes; write whatever is left.
  const size_t total = kLengthPrefix + payload.size();
  if (static_cast<size_t>(sent) < total) {
    std::vector<uint8_t> rest;
    rest.insert(rest.end(), prefix, prefix + kLengthPrefix);
    rest.insert(rest.end(), payload.begin(), payload.end());
    if (!WriteAll(rest.data() + sent, total - sent)) {
      CloseClient();
      return false;
    }
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
