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

bool SocketPair(int fds[2]) {
  fds[0] = fds[1] = -1;
  char temp[MAX_PATH];
  const DWORD length = GetTempPathA(sizeof(temp), temp);
  if (length == 0 || length >= sizeof(temp)) return false;
  static std::atomic<unsigned> serial{0};
  const std::string path = std::string(temp) + "raccoon-wake-" +
                           std::to_string(GetCurrentProcessId()) + "-" +
                           std::to_string(serial++) + ".sock";
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (path.size() >= sizeof(address.sun_path)) return false;
  std::strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);

  const int listener = OpenSocket(AF_UNIX);
  if (listener < 0) return false;
  DeleteFileA(path.c_str());
  bool ok = bind(AsSocket(listener), reinterpret_cast<sockaddr*>(&address),
                 sizeof(address)) == 0 &&
            listen(AsSocket(listener), 1) == 0;
  int client = ok ? OpenSocket(AF_UNIX) : -1;
  int server = -1;
  if (client >= 0) {
    // Non-blocking: the connect completes once the listener has it queued,
    // which on a local socket is at once.
    if (connect(AsSocket(client), reinterpret_cast<sockaddr*>(&address),
                sizeof(address)) != 0 &&
        WSAGetLastError() != WSAEWOULDBLOCK) {
      ok = false;
    }
    WSAPOLLFD ready{AsSocket(listener), POLLRDNORM, 0};
    if (ok && WSAPoll(&ready, 1, 5000) == 1) server = AcceptSocket(listener);
  }
  CloseSocket(listener);
  DeleteFileA(path.c_str());
  if (client < 0 || server < 0) {
    CloseSocket(client);
    CloseSocket(server);
    return false;
  }
  fds[0] = server;
  fds[1] = client;
  return true;
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
