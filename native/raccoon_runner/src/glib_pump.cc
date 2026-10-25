#if RACCOON_HAS_PLUGINS && !defined(__APPLE__) && !defined(_WIN32)
#include "glib_pump.h"

namespace raccoon {

namespace {

// How often a nested loop's source takes a turn: under a 60 Hz frame.
constexpr gint64 kModalTurnMicros = 8000;

}  // namespace

struct GlibPump::ModalSource {
  GSource source;
  GlibPump* pump;
  gint64 due;
};

// Ready only in an iteration the pump did not start, every few
// milliseconds; in the pump's own it neither runs nor shortens the wait.
gboolean GlibPump::ModalPrepare(GSource* source, gint* timeout) {
  auto* modal = reinterpret_cast<ModalSource*>(source);
  *timeout = -1;
  if (modal->pump->own_ || !modal->pump->turn_) return FALSE;
  const gint64 left = modal->due - g_source_get_time(source);
  if (left <= 0) return TRUE;
  *timeout = static_cast<gint>((left + 999) / 1000);
  return FALSE;
}

gboolean GlibPump::ModalCheck(GSource* source) {
  auto* modal = reinterpret_cast<ModalSource*>(source);
  return !modal->pump->own_ && modal->pump->turn_ && g_source_get_time(source) >= modal->due;
}

gboolean GlibPump::ModalDispatch(GSource* source, GSourceFunc, gpointer) {
  auto* modal = reinterpret_cast<ModalSource*>(source);
  GlibPump* pump = modal->pump;
  modal->due = g_source_get_time(source) + kModalTurnMicros;
  if (!pump->turning_) {
    pump->turning_ = true;
    pump->turn_();
    pump->turning_ = false;
  }
  return G_SOURCE_CONTINUE;
}

GlibPump::GlibPump(EventLoop& loop) : loop_(loop), context_(g_main_context_default()) {
  g_main_context_acquire(context_);
  static GSourceFuncs funcs = {ModalPrepare, ModalCheck, ModalDispatch, nullptr, nullptr,
                               nullptr};
  modal_ = g_source_new(&funcs, sizeof(ModalSource));
  reinterpret_cast<ModalSource*>(modal_)->pump = this;
  reinterpret_cast<ModalSource*>(modal_)->due = 0;
  g_source_attach(modal_, context_);
  loop_.SetExternal(
      [this](std::vector<pollfd>& fds, int& timeout_ms) { Prepare(fds, timeout_ms); },
      [this](const pollfd* fds, size_t count) { Dispatch(fds, count); });
}

GlibPump::~GlibPump() {
  loop_.SetExternal(nullptr, nullptr);
  g_source_destroy(modal_);
  g_source_unref(modal_);
  g_main_context_release(context_);
}

void GlibPump::Prepare(std::vector<pollfd>& fds, int& timeout_ms) {
  // A turn from the modal source: the descriptors only, the context is the
  // nested loop's.
  if (turning_) return;
  own_ = true;
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
  own_ = false;
  fds_.resize(count);
  for (const GPollFD& fd : fds_) {
    fds.push_back({fd.fd, static_cast<short>(fd.events), 0});
  }
  if (glib_timeout >= 0 && (timeout_ms < 0 || glib_timeout < timeout_ms)) {
    timeout_ms = glib_timeout;
  }
}

void GlibPump::Dispatch(const pollfd* fds, size_t count) {
  if (turning_) return;
  for (size_t i = 0; i < count && i < fds_.size(); ++i) {
    fds_[i].revents = static_cast<gushort>(fds[i].revents);
  }
  own_ = true;
  const bool ready =
      g_main_context_check(context_, priority_, fds_.data(), static_cast<gint>(fds_.size()));
  own_ = false;
  // A source dispatched here may run a nested loop: its iterations are not
  // the pump's.
  if (ready) g_main_context_dispatch(context_);
}

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS && !__APPLE__ && !_WIN32
