#if RACCOON_HAS_PLUGINS && defined(_WIN32)
#include "message_pump.h"

namespace raccoon {

namespace {

// The pump of the platform thread, for the hook and the timer, which take
// no user data. One per process: the runner has one platform thread.
MessagePump* g_pump = nullptr;

// How often a modal loop's timer takes a turn: under a 60 Hz frame.
constexpr UINT kModalTurnMs = 8;

}  // namespace

MessagePump::MessagePump(EventLoop& loop) : loop_(loop), event_(WSACreateEvent()) {
  g_pump = this;
  hook_ = SetWindowsHookExW(WH_MSGFILTER, OnFilteredMessage, nullptr, GetCurrentThreadId());
  loop_.SetWaiter([this](pollfd* fds, size_t count, int timeout_ms) {
    return Wait(fds, count, timeout_ms);
  });
}

MessagePump::~MessagePump() {
  loop_.SetWaiter(nullptr);
  if (timer_ != 0) KillTimer(nullptr, timer_);
  if (hook_ != nullptr) UnhookWindowsHookEx(hook_);
  WSACloseEvent(event_);
  g_pump = nullptr;
}

// Everything the thread's windows have been sent or posted, as a message
// loop would hand it out.
void MessagePump::Dispatch() {
  MSG message;
  while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
}

// A message of a dialog, message box or menu loop: one is running, so the
// runner's turns come from the timer until the loop gives back.
LRESULT CALLBACK MessagePump::OnFilteredMessage(int code, WPARAM wparam, LPARAM lparam) {
  MessagePump* pump = g_pump;
  if (code >= 0 && pump != nullptr && !pump->modal_ && pump->turn_) {
    pump->modal_ = true;
    pump->timer_ = SetTimer(nullptr, 0, kModalTurnMs, OnTimer);
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

void CALLBACK MessagePump::OnTimer(HWND, UINT, UINT_PTR, DWORD) {
  MessagePump* pump = g_pump;
  if (pump == nullptr || !pump->modal_ || pump->turning_) return;
  pump->turning_ = true;
  pump->turn_();
  pump->turning_ = false;
}

int MessagePump::Wait(pollfd* fds, size_t count, int timeout_ms) {
  // A turn from the timer, inside a modal loop: the sockets now, nothing
  // dispatched here, nothing waited for.
  if (turning_) return WSAPoll(fds, static_cast<ULONG>(count), 0);
  // The runner's own loop is turning again: whatever modal loop there was
  // has given back.
  if (modal_) {
    modal_ = false;
    KillTimer(nullptr, timer_);
    timer_ = 0;
  }
  Dispatch();
  const int ready = WSAPoll(fds, static_cast<ULONG>(count), 0);
  if (ready != 0) return ready;
  // The sockets signal the event while they are watched; messages wake the
  // wait by themselves.
  for (size_t i = 0; i < count; ++i) {
    // A socket the loop waits on to write, the client's while its queue is
    // full, wakes the wait when it takes more (#147).
    const long write = (fds[i].events & POLLOUT) != 0 ? FD_WRITE : 0;
    WSAEventSelect(fds[i].fd, event_, FD_READ | FD_ACCEPT | FD_CLOSE | write);
  }
  MsgWaitForMultipleObjectsEx(1, &event_,
                              timeout_ms < 0 ? INFINITE : static_cast<DWORD>(timeout_ms),
                              QS_ALLINPUT, MWMO_INPUTAVAILABLE);
  // No longer watched: the sockets stay non-blocking, as the loop wants.
  for (size_t i = 0; i < count; ++i) WSAEventSelect(fds[i].fd, nullptr, 0);
  WSAResetEvent(event_);
  Dispatch();
  return WSAPoll(fds, static_cast<ULONG>(count), 0);
}

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS && _WIN32
