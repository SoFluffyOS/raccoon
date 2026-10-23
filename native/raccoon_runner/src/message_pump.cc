#if RACCOON_HAS_PLUGINS && defined(_WIN32)
#include "message_pump.h"

#include <windows.h>

namespace raccoon {

namespace {

// Everything the thread's windows have been sent or posted, as a message
// loop would hand it out.
void DispatchMessages() {
  MSG message;
  while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
}

}  // namespace

MessagePump::MessagePump(EventLoop& loop) : loop_(loop), event_(WSACreateEvent()) {
  loop_.SetWaiter([this](pollfd* fds, size_t count, int timeout_ms) {
    return Wait(fds, count, timeout_ms);
  });
}

MessagePump::~MessagePump() {
  loop_.SetWaiter(nullptr);
  WSACloseEvent(event_);
}

int MessagePump::Wait(pollfd* fds, size_t count, int timeout_ms) {
  DispatchMessages();
  const int ready = WSAPoll(fds, static_cast<ULONG>(count), 0);
  if (ready != 0) return ready;
  // The sockets signal the event while they are watched; messages wake the
  // wait by themselves.
  for (size_t i = 0; i < count; ++i) {
    WSAEventSelect(fds[i].fd, event_, FD_READ | FD_ACCEPT | FD_CLOSE);
  }
  MsgWaitForMultipleObjectsEx(1, &event_,
                              timeout_ms < 0 ? INFINITE : static_cast<DWORD>(timeout_ms),
                              QS_ALLINPUT, MWMO_INPUTAVAILABLE);
  // No longer watched: the sockets stay non-blocking, as the loop wants.
  for (size_t i = 0; i < count; ++i) WSAEventSelect(fds[i].fd, nullptr, 0);
  WSAResetEvent(event_);
  DispatchMessages();
  return WSAPoll(fds, static_cast<ULONG>(count), 0);
}

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS && _WIN32
