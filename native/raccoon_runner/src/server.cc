#include "server.h"

#if defined(_WIN32)
#include "win_sockets.h"
#else
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>
#endif

#include <algorithm>
#include <cerrno>
#include <cstring>

namespace raccoon {

namespace {

constexpr size_t kLengthPrefix = 4;
constexpr size_t kMaxMessage = 64 * 1024 * 1024;

// Sockets are non-blocking and close-on-exec, and a client that went away
// must fail a send with EPIPE rather than raise SIGPIPE. Linux asks for all of
// it in the calls themselves; macOS sets the flags afterwards and silences
// SIGPIPE per socket. Windows has neither signal nor exec: its sockets are
// made non-blocking and kept from the programs the app starts, and nothing
// rides along with the bytes.
#if defined(__linux__)

constexpr int kSendFlags = MSG_NOSIGNAL;
// Received descriptors must not leak into the apps the engine may spawn;
// Linux closes them on exec from recvmsg, elsewhere fcntl does it.
constexpr int kRecvFlags = MSG_CMSG_CLOEXEC;

int OpenListenSocket() {
  return socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
}

int AcceptClient(int listen_fd) {
  return accept4(listen_fd, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
}

#elif defined(_WIN32)

constexpr int kSendFlags = 0;

int OpenListenSocket() { return OpenSocket(AF_UNIX); }

int AcceptClient(int listen_fd) { return AcceptSocket(listen_fd); }

#else

constexpr int kSendFlags = 0;
constexpr int kRecvFlags = 0;

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

// The calls whose names or errors differ on Windows, where a socket is not a
// file descriptor.
#if defined(_WIN32)

void CloseFd(int fd) { CloseSocket(fd); }

void RemoveSocketFile(const std::string& path) { DeleteFileA(path.c_str()); }

std::string ErrorText(const char* what) { return SocketError(what); }

bool WouldBlock() { return WSAGetLastError() == WSAEWOULDBLOCK; }

int SendSome(int fd, const uint8_t* data, size_t size) {
  const int chunk = size > INT32_MAX ? INT32_MAX : static_cast<int>(size);
  return send(AsSocket(fd), reinterpret_cast<const char*>(data), chunk, kSendFlags);
}

int RecvSome(int fd, uint8_t* buffer, size_t size) {
  return recv(AsSocket(fd), reinterpret_cast<char*>(buffer), static_cast<int>(size), 0);
}

void ShutWrite(int fd) { shutdown(AsSocket(fd), SD_SEND); }

bool WaitWritable(int fd, int timeout_ms) {
  WSAPOLLFD wait{AsSocket(fd), POLLWRNORM, 0};
  return WSAPoll(&wait, 1, timeout_ms) > 0;
}

#else

void CloseFd(int fd) { close(fd); }

void RemoveSocketFile(const std::string& path) { unlink(path.c_str()); }

std::string ErrorText(const char* what) {
  return std::string(what) + ": " + std::strerror(errno);
}

bool WouldBlock() { return errno == EAGAIN || errno == EWOULDBLOCK; }

ssize_t SendSome(int fd, const uint8_t* data, size_t size) {
  return send(fd, data, size, kSendFlags);
}

ssize_t RecvSome(int fd, uint8_t* buffer, size_t size) {
  return read(fd, buffer, size);
}

void ShutWrite(int fd) { shutdown(fd, SHUT_WR); }

bool WaitWritable(int fd, int timeout_ms) {
  pollfd wait{fd, POLLOUT, 0};
  return poll(&wait, 1, timeout_ms) > 0;
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
  // The runner is past its engine by now: what the client sent last is
  // dropped, not dispatched to handlers whose state is gone (#138).
  handler_ = Handler{};
  CloseClient();
  while (!lingering_.empty()) Unlinger(lingering_.front());
  if (listen_fd_ >= 0) {
    loop_.Unwatch(listen_fd_);
    CloseFd(listen_fd_);
    RemoveSocketFile(socket_path_);
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
    *error = ErrorText("socket");
    return false;
  }
  RemoveSocketFile(socket_path);
  if (bind(listen_fd_, reinterpret_cast<sockaddr*>(&address),
           sizeof(address)) < 0) {
    *error = ErrorText("bind");
    return false;
  }
  if (listen(listen_fd_, 1) < 0) {
    *error = ErrorText("listen");
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
    // One client at a time: tell the newcomer who has the runner, then hang
    // up, so it can say so instead of showing a dead pane.
    v1::RunnerMessage busy;
    busy.mutable_busy()->set_pid(client_pid_);
    std::string bytes;
    busy.SerializeToString(&bytes);
    const uint32_t length = static_cast<uint32_t>(bytes.size());
    const uint8_t prefix[4] = {
        static_cast<uint8_t>(length & 0xff), static_cast<uint8_t>((length >> 8) & 0xff),
        static_cast<uint8_t>((length >> 16) & 0xff), static_cast<uint8_t>((length >> 24) & 0xff)};
    if (WriteAllTo(fd, prefix, sizeof(prefix))) {
      WriteAllTo(fd, reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size());
    }
    Linger(fd);
    return;
  }
  client_fd_ = fd;
  inbox_.clear();
  loop_.Watch(client_fd_, POLLIN,
              [this](short revents) { OnClientReadable(revents); });
  if (handler_.on_client_connected) handler_.on_client_connected();
}

// A newcomer is not closed right after the Busy reply: its hello may still
// be unread, and closing over unread bytes resets the connection, which on
// macOS can reach it before the reply does. The write side shuts instead,
// so it reads the reply and then an end, and whatever it sends is read and
// dropped until it hangs up.
void RunnerServer::Linger(int fd) {
  ShutWrite(fd);
  if (lingering_.size() >= kMaxLingering) Unlinger(lingering_.front());
  lingering_.push_back(fd);
  loop_.Watch(fd, POLLIN, [this, fd](short) {
    uint8_t buffer[4096];
    while (true) {
      const auto got = RecvSome(fd, buffer, sizeof(buffer));
      if (got > 0) continue;
      if (got < 0 && WouldBlock()) return;
      break;
    }
    Unlinger(fd);
  });
}

void RunnerServer::Unlinger(int fd) {
  const auto found = std::find(lingering_.begin(), lingering_.end(), fd);
  if (found == lingering_.end()) return;
  lingering_.erase(found);
  loop_.Unwatch(fd);
  CloseFd(fd);
}

bool RunnerServer::ReadAvailable() {
  uint8_t buffer[64 * 1024];
#if !defined(_WIN32)
  alignas(cmsghdr) uint8_t control[CMSG_SPACE(sizeof(int) * 16)];
#endif
  while (true) {
#if defined(_WIN32)
    // Nothing rides along on Windows, raw client or not.
    const int got = RecvSome(client_fd_, buffer, sizeof(buffer));
#else
    ssize_t got;
    if (handler_.on_raw) {
      // A raw client may attach descriptors; they ride with the first bytes
      // of their message and are kept in order for the handler.
      iovec part{buffer, sizeof(buffer)};
      msghdr header{};
      header.msg_iov = &part;
      header.msg_iovlen = 1;
      header.msg_control = control;
      header.msg_controllen = sizeof(control);
      got = recvmsg(client_fd_, &header, kRecvFlags);
      if (got > 0) {
        for (cmsghdr* cmsg = CMSG_FIRSTHDR(&header); cmsg != nullptr;
             cmsg = CMSG_NXTHDR(&header, cmsg)) {
          if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS) continue;
          const size_t count = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
          const int* fds = reinterpret_cast<const int*>(CMSG_DATA(cmsg));
          for (size_t i = 0; i < count; ++i) {
            // Where recvmsg cannot close them on exec, do it by hand.
            if (kRecvFlags == 0) fcntl(fds[i], F_SETFD, FD_CLOEXEC);
            fds_in_.push_back(fds[i]);
          }
        }
      }
    } else {
      got = RecvSome(client_fd_, buffer, sizeof(buffer));
    }
#endif
    if (got > 0) {
      inbox_.insert(inbox_.end(), buffer, buffer + got);
      continue;
    }
    return got == 0 || !WouldBlock();
  }
}

void RunnerServer::OnClientReadable(short revents) {
  // A hang-up often arrives together with the last bytes, so drain first: a
  // message sent right before the client closed is still dispatched.
  bool closed = (revents & (POLLERR | POLLNVAL)) != 0;
  closed = ReadAvailable() || closed;
  DispatchInbox();
  if (closed) CloseClient();
}

void RunnerServer::DispatchInbox() {
  while (inbox_.size() - inbox_read_ >= kLengthPrefix) {
    const uint32_t length = ReadLength(inbox_.data() + inbox_read_);
    if (length > kMaxMessage) {
      CloseClient();
      return;
    }
    if (inbox_.size() - inbox_read_ - kLengthPrefix < length) break;
    const size_t at = inbox_read_ + kLengthPrefix;
    inbox_read_ = at + length;
    if (handler_.on_raw) {
      // A copy: a handler that closes the client reads into inbox_.
      const std::vector<uint8_t> raw(inbox_.begin() + at, inbox_.begin() + at + length);
      handler_.on_raw(raw.data(), length, fds_in_);
    } else {
      v1::ClientMessage message;
      if (message.ParseFromArray(inbox_.data() + at, static_cast<int>(length))) {
        Dispatch(message);
      }
    }
    if (client_fd_ < 0) return;
  }
  inbox_.erase(inbox_.begin(), inbox_.begin() + inbox_read_);
  inbox_read_ = 0;
}

void RunnerServer::Dispatch(const v1::ClientMessage& message) {
  switch (message.message_case()) {
    case v1::ClientMessage::kHello:
      client_pid_ = message.hello().pid();
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
    case v1::ClientMessage::kTextEditing:
      if (handler_.on_text_editing) {
        handler_.on_text_editing(message.text_editing());
      }
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
  if (client_fd_ < 0 || closing_) return;
  closing_ = true;
  // What the client sent before hanging up still counts, a Shutdown above
  // all: a send that failed because the client is gone must not drop it.
  ReadAvailable();
  DispatchInbox();
  closing_ = false;
  if (client_fd_ < 0) return;
  loop_.Unwatch(client_fd_);
  CloseFd(client_fd_);
  client_fd_ = -1;
  // Gone: a newcomer is not told it holds the runner.
  client_pid_ = 0;
  inbox_.clear();
  inbox_read_ = 0;
#if !defined(_WIN32)
  for (int fd : fds_in_) close(fd);
#endif
  fds_in_.clear();
  if (handler_.on_client_disconnected) handler_.on_client_disconnected();
}

bool RunnerServer::WriteAll(const uint8_t* data, size_t size) {
  return WriteAllTo(client_fd_, data, size);
}

bool RunnerServer::WriteAllTo(int fd, const uint8_t* data, size_t size) {
  size_t sent = 0;
  while (sent < size) {
    const auto wrote = SendSome(fd, data + sent, size - sent);
    if (wrote >= 0) {
      sent += static_cast<size_t>(wrote);
      continue;
    }
    if (WouldBlock()) {
      if (!WaitWritable(fd, 5000)) return false;
      continue;
    }
    return false;
  }
  return true;
}

bool RunnerServer::SendWithFds(const v1::RunnerMessage& message,
                               const std::vector<int>& fds) {
  std::string serialized;
  if (!message.SerializeToString(&serialized)) return false;
  return SendBytesWithFds(
      std::vector<uint8_t>(serialized.begin(), serialized.end()), fds);
}

#if defined(_WIN32)

bool RunnerServer::SendBytesWithFds(const std::vector<uint8_t>& payload,
                                    const std::vector<int>& fds) {
  // No descriptor crosses a Windows socket; a set named by IDs still goes.
  if (client_fd_ < 0 || !fds.empty()) return false;
  const uint32_t length = static_cast<uint32_t>(payload.size());
  const uint8_t prefix[kLengthPrefix] = {
      static_cast<uint8_t>(length), static_cast<uint8_t>(length >> 8),
      static_cast<uint8_t>(length >> 16), static_cast<uint8_t>(length >> 24)};
  if (!WriteAll(prefix, kLengthPrefix) || !WriteAll(payload.data(), payload.size())) {
    CloseClient();
    return false;
  }
  return true;
}

#else

bool RunnerServer::SendBytesWithFds(const std::vector<uint8_t>& payload,
                                    const std::vector<int>& fds) {
  if (client_fd_ < 0) return false;
  const uint32_t length = static_cast<uint32_t>(payload.size());
  uint8_t prefix[kLengthPrefix] = {
      static_cast<uint8_t>(length), static_cast<uint8_t>(length >> 8),
      static_cast<uint8_t>(length >> 16), static_cast<uint8_t>(length >> 24)};
  iovec parts[2] = {{prefix, kLengthPrefix},
                    {const_cast<uint8_t*>(payload.data()), payload.size()}};
  std::vector<uint8_t> control(CMSG_SPACE(sizeof(int) * fds.size()));
  msghdr header{};
  header.msg_iov = parts;
  header.msg_iovlen = 2;
  // Nothing to attach (a set named by IDs) goes as plain bytes.
  if (!fds.empty()) {
    header.msg_control = control.data();
    header.msg_controllen = control.size();
    cmsghdr* cmsg = CMSG_FIRSTHDR(&header);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int) * fds.size());
    std::memcpy(CMSG_DATA(cmsg), fds.data(), sizeof(int) * fds.size());
  }
  ssize_t sent;
  while (true) {
    sent = sendmsg(client_fd_, &header, kSendFlags);
    if (sent >= 0) break;
    if (WouldBlock()) {
      if (!WaitWritable(client_fd_, 5000)) {
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

#endif

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
