#if RACCOON_HAS_PLUGINS
#include "glib_pump.h"

namespace raccoon {

GlibPump::GlibPump(EventLoop& loop) : loop_(loop), context_(g_main_context_default()) {
  g_main_context_acquire(context_);
  loop_.SetExternal(
      [this](std::vector<pollfd>& fds, int& timeout_ms) { Prepare(fds, timeout_ms); },
      [this](const pollfd* fds, size_t count) { Dispatch(fds, count); });
}

GlibPump::~GlibPump() {
  loop_.SetExternal(nullptr, nullptr);
  g_main_context_release(context_);
}

void GlibPump::Prepare(std::vector<pollfd>& fds, int& timeout_ms) {
  g_main_context_prepare(context_, &priority_);
  gint glib_timeout = -1;
  if (fds_.empty()) fds_.resize(8);
  gint count = g_main_context_query(context_, priority_, &glib_timeout, fds_.data(),
                                    static_cast<gint>(fds_.size()));
  if (static_cast<size_t>(count) > fds_.size()) {
    fds_.resize(count);
    count = g_main_context_query(context_, priority_, &glib_timeout, fds_.data(),
                                 static_cast<gint>(fds_.size()));
  }
  fds_.resize(count);
  for (const GPollFD& fd : fds_) {
    fds.push_back({fd.fd, static_cast<short>(fd.events), 0});
  }
  if (glib_timeout >= 0 && (timeout_ms < 0 || glib_timeout < timeout_ms)) {
    timeout_ms = glib_timeout;
  }
}

void GlibPump::Dispatch(const pollfd* fds, size_t count) {
  for (size_t i = 0; i < count && i < fds_.size(); ++i) {
    fds_[i].revents = static_cast<gushort>(fds[i].revents);
  }
  if (g_main_context_check(context_, priority_, fds_.data(), static_cast<gint>(fds_.size()))) {
    g_main_context_dispatch(context_);
  }
}

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS
