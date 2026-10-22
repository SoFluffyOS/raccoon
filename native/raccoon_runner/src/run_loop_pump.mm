#if RACCOON_HAS_PLUGINS && defined(__APPLE__)
#include "run_loop_pump.h"

#import <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <sys/event.h>
#include <unistd.h>

#include <vector>

namespace raccoon {

// One kqueue for the loop's descriptors, watched by the run loop as a
// single source. Each wait adds the descriptors as one-shot events and
// deletes them after, so a descriptor closed and reused in between is never
// a stale entry.
struct RunLoopPump::Impl {
  int queue = -1;
  CFFileDescriptorRef descriptor = nullptr;
  CFRunLoopSourceRef source = nullptr;
  std::vector<struct kevent> changes;
};

namespace {

// Nothing to do: the run loop returns once a source fired, and the loop
// looks at its descriptors itself.
void OnQueueReady(CFFileDescriptorRef, CFOptionFlags, void*) {}

// AppKit's events, for plugins that open panels or alerts: they queue on
// the run loop and wait for someone to hand them out.
void DispatchEvents() {
  if (NSApp == nil) return;
  while (true) {
    NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                        untilDate:nil
                                           inMode:NSDefaultRunLoopMode
                                          dequeue:YES];
    if (event == nil) return;
    [NSApp sendEvent:event];
  }
}

}  // namespace

RunLoopPump::RunLoopPump(EventLoop& loop) : loop_(loop), impl_(std::make_unique<Impl>()) {
  impl_->queue = kqueue();
  if (impl_->queue < 0) return;
  impl_->descriptor = CFFileDescriptorCreate(kCFAllocatorDefault, impl_->queue, false,
                                             OnQueueReady, nullptr);
  impl_->source = CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, impl_->descriptor, 0);
  CFRunLoopAddSource(CFRunLoopGetMain(), impl_->source, kCFRunLoopDefaultMode);
  loop_.SetWaiter([this](pollfd* fds, size_t count, int timeout_ms) {
    return Wait(fds, count, timeout_ms);
  });
}

RunLoopPump::~RunLoopPump() {
  loop_.SetWaiter(nullptr);
  if (impl_->source != nullptr) {
    CFRunLoopRemoveSource(CFRunLoopGetMain(), impl_->source, kCFRunLoopDefaultMode);
    CFRelease(impl_->source);
  }
  if (impl_->descriptor != nullptr) {
    CFFileDescriptorInvalidate(impl_->descriptor);
    CFRelease(impl_->descriptor);
  }
  if (impl_->queue >= 0) close(impl_->queue);
}

int RunLoopPump::Wait(pollfd* fds, size_t count, int timeout_ms) {
  // Ready already, or not to wait: turn the run loop once without blocking
  // so the main queue keeps moving while the loop is busy.
  int ready = poll(fds, count, 0);
  if (ready != 0 || timeout_ms == 0 || impl_->queue < 0) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
    DispatchEvents();
    return ready != 0 ? ready : poll(fds, count, 0);
  }
  auto& changes = impl_->changes;
  changes.clear();
  for (size_t i = 0; i < count; ++i) {
    const auto fd = static_cast<uintptr_t>(fds[i].fd);
    if (fds[i].events & POLLIN) {
      changes.push_back({fd, EVFILT_READ, EV_ADD | EV_ONESHOT | EV_RECEIPT, 0, 0, nullptr});
    }
    if (fds[i].events & POLLOUT) {
      changes.push_back({fd, EVFILT_WRITE, EV_ADD | EV_ONESHOT | EV_RECEIPT, 0, 0, nullptr});
    }
  }
  // With EV_RECEIPT every change answers in the event list, errors
  // included, so one bad descriptor does not stop the rest.
  std::vector<struct kevent> receipts(changes.size());
  kevent(impl_->queue, changes.data(), static_cast<int>(changes.size()), receipts.data(),
         static_cast<int>(receipts.size()), nullptr);
  CFFileDescriptorEnableCallBacks(impl_->descriptor, kCFFileDescriptorReadCallBack);
  const CFTimeInterval seconds = timeout_ms < 0 ? 1.0e10 : timeout_ms / 1000.0;
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, true);
  for (auto& change : changes) change.flags = EV_DELETE | EV_RECEIPT;
  kevent(impl_->queue, changes.data(), static_cast<int>(changes.size()), receipts.data(),
         static_cast<int>(receipts.size()), nullptr);
  DispatchEvents();
  return poll(fds, count, 0);
}

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS && __APPLE__
