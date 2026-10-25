#pragma once
// GLib's main context, pumped from the runner's own loop: plugins post
// idles, run GTasks and talk GDBus on it. The context's descriptors and
// timeout join each poll of the loop; its sources are dispatched after.
//
// A plugin's nested main loop (gtk_dialog_run, gtk_native_dialog_run, a
// g_main_loop_run of its own) iterates the context itself until it ends,
// which holds the runner's loop. A source of the pump's, which wants to
// run only in an iteration the pump did not start, takes the loop's turns
// meanwhile.
#if RACCOON_HAS_PLUGINS && !defined(__APPLE__) && !defined(_WIN32)
#include <glib.h>

#include <functional>
#include <vector>

#include "event_loop.h"

namespace raccoon {

class GlibPump {
 public:
  // Takes the default context for the calling thread and hooks |loop|.
  explicit GlibPump(EventLoop& loop);
  ~GlibPump();
  GlibPump(const GlibPump&) = delete;
  GlibPump& operator=(const GlibPump&) = delete;

  // What a turn of the runner's loop is, for while a nested loop holds it:
  // its work, then a look at the descriptors without waiting.
  void SetModalTurn(std::function<void()> turn) { turn_ = std::move(turn); }

 private:
  struct ModalSource;
  static gboolean ModalPrepare(GSource* source, gint* timeout);
  static gboolean ModalCheck(GSource* source);
  static gboolean ModalDispatch(GSource* source, GSourceFunc, gpointer);

  void Prepare(std::vector<pollfd>& fds, int& timeout_ms);
  void Dispatch(const pollfd* fds, size_t count);

  EventLoop& loop_;
  GMainContext* context_;
  int priority_ = 0;
  std::vector<GPollFD> fds_;
  std::function<void()> turn_;
  GSource* modal_ = nullptr;
  // In the pump's own prepare or check: an iteration of the runner's loop,
  // not a nested one.
  bool own_ = false;
  // Inside a turn taken from the modal source: the loop's look at its
  // descriptors leaves the context to the nested loop.
  bool turning_ = false;
};

}  // namespace raccoon
#else
namespace raccoon {
// Without plugins there is nothing to pump; the type stays so main names
// it either way.
class GlibPump {};
}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS && !__APPLE__ && !_WIN32
