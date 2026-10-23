#pragma once
// The thread's Win32 messages, pumped by the runner's own loop: Windows
// plugins open dialogs, use COM and post messages to windows of the
// platform thread, all of which need a message loop there. While the pump
// lives the loop waits in MsgWaitForMultipleObjectsEx, with its sockets
// signalling an event, instead of WSAPoll; the messages are dispatched
// after each wait.
//
// A plugin's modal dialog (a file picker, a message box) runs a message
// loop of its own until it closes, which holds the runner's. The pump
// notices one through a message filter hook, which Windows calls for the
// messages of dialog, message box and menu loops, and takes the loop's
// turns from a thread timer meanwhile: any message loop on the thread
// dispatches its WM_TIMER, a modal one included.
#if RACCOON_HAS_PLUGINS && defined(_WIN32)
#include <winsock2.h>
#include <windows.h>

#include <cstddef>
#include <functional>

#include "event_loop.h"

namespace raccoon {

class MessagePump {
 public:
  // Hooks |loop|, which must be turned by the thread whose messages these
  // are, the platform thread.
  explicit MessagePump(EventLoop& loop);
  ~MessagePump();
  MessagePump(const MessagePump&) = delete;
  MessagePump& operator=(const MessagePump&) = delete;

  // What a turn of the runner's loop is, for while a modal loop holds it:
  // its work, then a look at the sockets without waiting.
  void SetModalTurn(std::function<void()> turn) { turn_ = std::move(turn); }

 private:
  int Wait(pollfd* fds, size_t count, int timeout_ms);
  void Dispatch();
  static LRESULT CALLBACK OnFilteredMessage(int code, WPARAM wparam, LPARAM lparam);
  static void CALLBACK OnTimer(HWND, UINT, UINT_PTR, DWORD);

  EventLoop& loop_;
  WSAEVENT event_;
  HHOOK hook_ = nullptr;
  std::function<void()> turn_;
  // A modal loop holds the runner's, and the timer that turns it meanwhile.
  bool modal_ = false;
  UINT_PTR timer_ = 0;
  // Inside a turn taken from the timer: the loop's look at its sockets
  // must neither dispatch messages nor end the modal state.
  bool turning_ = false;
};

}  // namespace raccoon
#else
namespace raccoon {
// Without plugins there is nothing to pump; the type stays so main names
// it either way.
class MessagePump {};
}  // namespace raccoon
#endif
