#if defined(_WIN32)
#include "win_sockets.h"

#include <windows.h>

#include <atomic>
#include <cstring>
#include <mutex>

namespace raccoon {

namespace {

bool NotInherited(SOCKET socket) {
  return SetHandleInformation(reinterpret_cast<HANDLE>(socket), HANDLE_FLAG_INHERIT, 0) != 0;
}

bool NonBlocking(SOCKET socket) {
  u_long on = 1;
  return ioctlsocket(socket, FIONBIO, &on) == 0;
}

}  // namespace

bool StartWinsock() {
  static std::once_flag once;
  static bool started = false;
  std::call_once(once, [] {
    WSADATA data;
    started = WSAStartup(MAKEWORD(2, 2), &data) == 0;
  });
  return started;
}

int OpenSocket(int family) {
  if (!StartWinsock()) return -1;
  const SOCKET socket = WSASocketW(family, SOCK_STREAM, 0, nullptr, 0,
                                   WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
  if (socket == INVALID_SOCKET) return -1;
  if (!NonBlocking(socket)) {
    closesocket(socket);
    return -1;
  }
  return static_cast<int>(socket);
}

int AcceptSocket(int listen_fd) {
  const SOCKET socket = accept(AsSocket(listen_fd), nullptr, nullptr);
  if (socket == INVALID_SOCKET) return -1;
  if (!NonBlocking(socket) || !NotInherited(socket)) {
    closesocket(socket);
    return -1;
  }
  return static_cast<int>(socket);
}

namespace {

// Whether |server|, just accepted, is |client|'s other end: on the
// loopback any local process may connect first.
bool SamePair(int server, int client) {
  sockaddr_storage peer{}, ours{};
  int peer_length = sizeof(peer), ours_length = sizeof(ours);
  return getpeername(AsSocket(server), reinterpret_cast<sockaddr*>(&peer), &peer_length) == 0 &&
         getsockname(AsSocket(client), reinterpret_cast<sockaddr*>(&ours), &ours_length) == 0 &&
         peer_length == ours_length && std::memcmp(&peer, &ours, peer_length) == 0;
}

bool NoDelay(int fd) {
  const BOOL on = TRUE;
  return setsockopt(AsSocket(fd), IPPROTO_TCP, TCP_NODELAY,
                    reinterpret_cast<const char*>(&on), sizeof(on)) == 0;
}

// A connected pair through a listener at |address|: the listener goes once
// its one connection is accepted.
bool ConnectedPair(int family, sockaddr* address, int length, int fds[2]) {
  const int listener = OpenSocket(family);
  if (listener < 0) return false;
  bool ok = bind(AsSocket(listener), address, length) == 0 &&
            listen(AsSocket(listener), 1) == 0 &&
            getsockname(AsSocket(listener), address, &length) == 0;
  int client = ok ? OpenSocket(family) : -1;
  int server = -1;
  if (client >= 0) {
    // Non-blocking: the connect completes once the listener has it queued,
    // which on a local socket is at once.
    if (connect(AsSocket(client), address, length) != 0 &&
        WSAGetLastError() != WSAEWOULDBLOCK) {
      ok = false;
    }
    // A few tries, for a stranger's connection that came first.
    for (int tries = 0; ok && server < 0 && tries < 4; ++tries) {
      WSAPOLLFD ready{AsSocket(listener), POLLRDNORM, 0};
      if (WSAPoll(&ready, 1, 5000) != 1) break;
      server = AcceptSocket(listener);
      if (server >= 0 && family == AF_INET && !SamePair(server, client)) {
        CloseSocket(server);
        server = -1;
      }
    }
    // A wake is one byte: Nagle would hold the next back until the first
    // is acknowledged, up to 200 ms later.
    if (server >= 0 && family == AF_INET && (!NoDelay(server) || !NoDelay(client))) {
      CloseSocket(server);
      server = -1;
    }
  }
  CloseSocket(listener);
  if (client < 0 || server < 0) {
    CloseSocket(client);
    CloseSocket(server);
    return false;
  }
  fds[0] = server;
  fds[1] = client;
  return true;
}

}  // namespace

bool SocketPair(int fds[2]) {
  fds[0] = fds[1] = -1;
  char temp[MAX_PATH];
  const DWORD length = GetTempPathA(sizeof(temp), temp);
  if (length > 0 && length < sizeof(temp)) {
    static std::atomic<unsigned> serial{0};
    const std::string path = std::string(temp) + "raccoon-wake-" +
                             std::to_string(GetCurrentProcessId()) + "-" +
                             std::to_string(serial++) + ".sock";
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (path.size() < sizeof(address.sun_path)) {
      std::strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
      DeleteFileA(path.c_str());
      const bool made = ConnectedPair(AF_UNIX, reinterpret_cast<sockaddr*>(&address),
                                      sizeof(address), fds);
      DeleteFileA(path.c_str());
      if (made) return true;
    }
  }
  // A temp path too long for a socket's name, or one that takes none: the
  // loopback instead, which only ever carries a wake's byte (#126).
  sockaddr_in loopback{};
  loopback.sin_family = AF_INET;
  loopback.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  loopback.sin_port = 0;
  return ConnectedPair(AF_INET, reinterpret_cast<sockaddr*>(&loopback),
                       sizeof(loopback), fds);
}

void CloseSocket(int fd) {
  if (fd >= 0) closesocket(AsSocket(fd));
}

std::string SocketError(const char* what) {
  const int code = WSAGetLastError();
  char text[256] = {};
  FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr,
                 static_cast<DWORD>(code), 0, text, sizeof(text), nullptr);
  std::string message = text;
  while (!message.empty() && (message.back() == '\n' || message.back() == '\r' ||
                              message.back() == '.')) {
    message.pop_back();
  }
  return std::string(what) + ": " + message + " (" + std::to_string(code) + ")";
}

}  // namespace raccoon

#endif  // _WIN32
