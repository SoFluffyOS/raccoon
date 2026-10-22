#pragma once
// GLib's main context, pumped from the runner's own loop: plugins post
// idles, run GTasks and talk GDBus on it. The context's descriptors and
// timeout join each poll of the loop; its sources are dispatched after.
#if RACCOON_HAS_PLUGINS
#include <glib.h>

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

 private:
  void Prepare(std::vector<pollfd>& fds, int& timeout_ms);
  void Dispatch(const pollfd* fds, size_t count);

  EventLoop& loop_;
  GMainContext* context_;
  int priority_ = 0;
  std::vector<GPollFD> fds_;
};

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS
