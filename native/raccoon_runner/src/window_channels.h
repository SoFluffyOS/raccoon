#pragma once

// The window plugins' method channels, answered by the runner: the app's
// window is the pane the client shows, so the runner is its window host.
//
// Desktop apps call these at startup, often before any client is connected
// (Wonderous awaits desktop_window's setMinWindowSize before its first frame),
// and an unanswered call throws MissingPluginException. Sizes are reported
// from the pane in logical pixels; the pane's size belongs to the client, so
// requests to resize, move or go full screen are recorded, not applied, and
// everything else is answered as a successful no-op.
//
// Channels: desktop_window, window_manager, flutter/windowsize (window_size).

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "standard_codec.h"

namespace raccoon {

class WindowChannels {
 public:
  // The view's size in physical pixels and its device pixel ratio.
  void SetViewSize(size_t width, size_t height, double pixel_ratio);

  // Answers a message on one of the window channels into |reply| and returns
  // true; returns false for any other channel.
  bool Handle(const std::string& channel, const uint8_t* data, size_t size,
              std::vector<uint8_t>* reply);

 private:
  CodecValue DesktopWindow(const MethodCall& call);
  CodecValue WindowManager(const MethodCall& call);
  CodecValue WindowSize(const MethodCall& call);

  double logical_width() const;
  double logical_height() const;
  // [left, top, width, height] of the pane, which is also its only screen.
  CodecValue Frame() const;
  CodecValue Screen() const;
  void SetMinSize(double width, double height);
  void SetMaxSize(double width, double height);

  size_t width_ = 0;
  size_t height_ = 0;
  double pixel_ratio_ = 1.0;
  // 0 means no minimum, -1 no maximum, as window_size passes them.
  double min_width_ = 0;
  double min_height_ = 0;
  double max_width_ = -1;
  double max_height_ = -1;
  bool full_screen_ = false;
  bool borders_ = true;
  bool always_on_top_ = false;
  bool prevent_close_ = false;
  bool skip_taskbar_ = false;
  bool resizable_ = true;
  double opacity_ = 1.0;
  std::string title_;
};

}  // namespace raccoon
