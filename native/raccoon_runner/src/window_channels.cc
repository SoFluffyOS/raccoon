#include "window_channels.h"

#include <cstdio>
#include <cstdlib>

namespace raccoon {

namespace {

constexpr char kDesktopWindow[] = "desktop_window";
constexpr char kWindowManager[] = "window_manager";
constexpr char kWindowSize[] = "flutter/windowsize";

bool BoolArgument(const CodecValue& arguments, const std::string& key,
                  bool fallback) {
  const CodecValue& value = arguments.Get(key);
  return value.type() == CodecValue::Type::kBool ? value.bool_value() : fallback;
}

// window_size passes sizes as a [width, height] list.
bool ListPair(const CodecValue& value, double* first, double* second) {
  if (value.type() != CodecValue::Type::kList || value.items().size() < 2) {
    return false;
  }
  *first = value.items()[0].AsDouble(*first);
  *second = value.items()[1].AsDouble(*second);
  return true;
}

}  // namespace

void WindowChannels::SetViewSize(size_t width, size_t height,
                                 double pixel_ratio) {
  width_ = width;
  height_ = height;
  pixel_ratio_ = pixel_ratio > 0 ? pixel_ratio : 1.0;
}

bool WindowChannels::Handle(const std::string& channel, const uint8_t* data,
                            size_t size, std::vector<uint8_t>* reply) {
  if (channel != kDesktopWindow && channel != kWindowManager &&
      channel != kWindowSize) {
    return false;
  }
  MethodCall call;
  if (!DecodeMethodCall(data, size, &call)) {
    *reply = EncodeError("bad-call", "raccoon_runner could not decode a " +
                                         channel + " method call");
    return true;
  }
  if (std::getenv("RACCOON_TRACE") != nullptr) {
    std::fprintf(stderr, "🦝 %s.%s\n", channel.c_str(),
                 call.method.c_str());
  }
  CodecValue result;
  if (channel == kDesktopWindow) {
    result = DesktopWindow(call);
  } else if (channel == kWindowManager) {
    result = WindowManager(call);
  } else {
    result = WindowSize(call);
  }
  *reply = EncodeSuccess(result);
  return true;
}

CodecValue WindowChannels::DesktopWindow(const MethodCall& call) {
  const std::string& method = call.method;
  const CodecValue& args = call.arguments;
  if (method == "getWindowSize") {
    return CodecValue::List({CodecValue::Double(logical_width()),
                             CodecValue::Double(logical_height())});
  }
  if (method == "setMinWindowSize") {
    SetMinSize(args.Get("width").AsDouble(0), args.Get("height").AsDouble(0));
  } else if (method == "setMaxWindowSize") {
    SetMaxSize(args.Get("width").AsDouble(-1), args.Get("height").AsDouble(-1));
  } else if (method == "resetMaxWindowSize") {
    SetMaxSize(-1, -1);
  } else if (method == "getFullScreen") {
    return CodecValue::Bool(full_screen_);
  } else if (method == "setFullScreen") {
    full_screen_ = BoolArgument(args, "fullscreen", full_screen_);
  } else if (method == "toggleFullScreen") {
    full_screen_ = !full_screen_;
  } else if (method == "hasBorders") {
    return CodecValue::Bool(borders_);
  } else if (method == "setBorders") {
    borders_ = BoolArgument(args, "border", borders_);
  } else if (method == "toggleBorders") {
    borders_ = !borders_;
  } else if (method == "stayOnTop") {
    always_on_top_ = BoolArgument(args, "stayOnTop", true);
  }
  // setWindowSize, focus and anything newer: the pane's size and focus belong
  // to the client.
  return CodecValue();
}

CodecValue WindowChannels::WindowManager(const MethodCall& call) {
  const std::string& method = call.method;
  const CodecValue& args = call.arguments;
  if (method == "getBounds") {
    return CodecValue::Map({{"x", CodecValue::Double(0)},
                            {"y", CodecValue::Double(0)},
                            {"width", CodecValue::Double(logical_width())},
                            {"height", CodecValue::Double(logical_height())}});
  }
  if (method == "setMinimumSize") {
    SetMinSize(args.Get("width").AsDouble(0), args.Get("height").AsDouble(0));
  } else if (method == "setMaximumSize") {
    SetMaxSize(args.Get("width").AsDouble(-1), args.Get("height").AsDouble(-1));
  } else if (method == "setFullScreen") {
    full_screen_ = BoolArgument(args, "isFullScreen", full_screen_);
  } else if (method == "setTitle") {
    const CodecValue& title = args.Get("title");
    if (title.type() == CodecValue::Type::kString) title_ = title.string_value();
  } else if (method == "setOpacity") {
    opacity_ = args.Get("opacity").AsDouble(opacity_);
  } else if (method == "setAlwaysOnTop") {
    always_on_top_ = BoolArgument(args, "isAlwaysOnTop", always_on_top_);
  } else if (method == "setPreventClose") {
    prevent_close_ = BoolArgument(args, "isPreventClose", prevent_close_);
  } else if (method == "setSkipTaskbar") {
    skip_taskbar_ = BoolArgument(args, "isSkipTaskbar", skip_taskbar_);
  } else if (method == "setResizable") {
    resizable_ = BoolArgument(args, "isResizable", resizable_);
  }
  // The getters' Dart side casts the result, so each answers its type. The
  // pane is always shown and focused, never minimized or maximized, and is
  // moved and closed by the IDE, not by the app.
  if (method == "isFocused" || method == "isVisible") return CodecValue::Bool(true);
  if (method == "isMaximized" || method == "isMinimized" ||
      method == "isDockable" || method == "isMovable" ||
      method == "isMinimizable" || method == "isMaximizable" ||
      method == "isClosable" || method == "isAlwaysOnBottom" ||
      method == "hasShadow" || method == "undock" ||
      method == "grabKeyboard" || method == "ungrabKeyboard") {
    return CodecValue::Bool(false);
  }
  if (method == "isFullScreen") return CodecValue::Bool(full_screen_);
  if (method == "isResizable") return CodecValue::Bool(resizable_);
  if (method == "isAlwaysOnTop") return CodecValue::Bool(always_on_top_);
  if (method == "isPreventClose") return CodecValue::Bool(prevent_close_);
  if (method == "isSkipTaskbar") return CodecValue::Bool(skip_taskbar_);
  if (method == "getTitle") return CodecValue::String(title_);
  if (method == "getOpacity") return CodecValue::Double(opacity_);
  if (method == "getId" || method == "getTitleBarHeight") return CodecValue::Int(0);
  // ensureInitialized, waitUntilReadyToShow, show, focus, setBounds and the
  // rest of the setters: successful no-ops.
  return CodecValue();
}

CodecValue WindowChannels::WindowSize(const MethodCall& call) {
  const std::string& method = call.method;
  const CodecValue& args = call.arguments;
  if (method == "getScreenList") return CodecValue::List({Screen()});
  if (method == "getWindowInfo") {
    return CodecValue::Map({{"frame", Frame()},
                            {"scaleFactor", CodecValue::Double(pixel_ratio_)},
                            {"screen", Screen()}});
  }
  if (method == "getWindowMinimumSize") {
    return CodecValue::List(
        {CodecValue::Double(min_width_), CodecValue::Double(min_height_)});
  }
  if (method == "getWindowMaximumSize") {
    return CodecValue::List(
        {CodecValue::Double(max_width_), CodecValue::Double(max_height_)});
  }
  if (method == "setWindowMinimumSize") {
    double width = 0, height = 0;
    if (ListPair(args, &width, &height)) SetMinSize(width, height);
  } else if (method == "setWindowMaximumSize") {
    double width = -1, height = -1;
    if (ListPair(args, &width, &height)) SetMaxSize(width, height);
  } else if (method == "setWindowTitle") {
    if (args.type() == CodecValue::Type::kString) title_ = args.string_value();
  }
  // setWindowFrame, setWindowVisibility, setWindowTitleRepresentedUrl: no-ops.
  return CodecValue();
}

double WindowChannels::logical_width() const {
  return static_cast<double>(width_) / pixel_ratio_;
}

double WindowChannels::logical_height() const {
  return static_cast<double>(height_) / pixel_ratio_;
}

CodecValue WindowChannels::Frame() const {
  return CodecValue::List({CodecValue::Double(0), CodecValue::Double(0),
                           CodecValue::Double(logical_width()),
                           CodecValue::Double(logical_height())});
}

CodecValue WindowChannels::Screen() const {
  return CodecValue::Map({{"frame", Frame()},
                          {"visibleFrame", Frame()},
                          {"scaleFactor", CodecValue::Double(pixel_ratio_)}});
}

void WindowChannels::SetMinSize(double width, double height) {
  min_width_ = width;
  min_height_ = height;
}

void WindowChannels::SetMaxSize(double width, double height) {
  max_width_ = width;
  max_height_ = height;
}

}  // namespace raccoon
