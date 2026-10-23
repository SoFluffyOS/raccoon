#pragma once
// The thread's Win32 messages, pumped by the runner's own loop: Windows
// plugins open dialogs, use COM and post messages to windows of the
// platform thread, all of which need a message loop there. While the pump
// lives the loop waits in MsgWaitForMultipleObjectsEx, with its sockets
// signalling an event, instead of WSAPoll; the messages are dispatched
// after each wait.
#if RACCOON_HAS_PLUGINS && defined(_WIN32)
#include <winsock2.h>

#include <cstddef>

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

 private:
  int Wait(pollfd* fds, size_t count, int timeout_ms);

  EventLoop& loop_;
  WSAEVENT event_;
};

}  // namespace raccoon
#else
namespace raccoon {
// Without plugins there is nothing to pump; the type stays so main names
// it either way.
class MessagePump {};
}  // namespace raccoon
#endif
