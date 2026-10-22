#pragma once
// Windows only: what the loop and the server need from Winsock. It has
// AF_UNIX sockets since Windows 10 1803, so the runner listens on a socket
// file there as on the other hosts, but no socketpair, no descriptor passing
// and no fcntl. Sockets are kernel handles, which Windows keeps within 32
// bits, so they travel as the same int the other hosts use; INVALID_SOCKET
// comes out as -1.

#if defined(_WIN32)
#include <winsock2.h>
#include <afunix.h>

#include <string>

namespace raccoon {

// Starts Winsock once per process; false when it cannot be had.
bool StartWinsock();

inline SOCKET AsSocket(int fd) { return static_cast<SOCKET>(fd); }

// A non-blocking stream socket of |family| that programs the app starts do
// not inherit, or -1.
int OpenSocket(int family);
// Accepts a client of |listen_fd|, non-blocking and not inherited, or -1.
int AcceptSocket(int listen_fd);
// Two connected, non-blocking AF_UNIX sockets, through a socket file in the
// temporary directory that is gone again once they are connected.
bool SocketPair(int fds[2]);
void CloseSocket(int fd);
// "|what|: " and the last Winsock error's text.
std::string SocketError(const char* what);

}  // namespace raccoon

#endif  // _WIN32
