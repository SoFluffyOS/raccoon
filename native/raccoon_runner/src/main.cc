// raccoon_runner: hosts a Flutter app on the C embedder API.
//
//   raccoon_runner render --engine-dir DIR --assets DIR --icu FILE [--out F]
//   raccoon_runner serve  --engine-dir DIR --assets DIR --icu FILE --socket P

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "engine_host.h"
#include "event_loop.h"
#include "flutter_embedder.h"
#include "server.h"

namespace {

struct Options {
  std::string command;
  raccoon::EngineOptions engine;
  std::string out = "frame.ppm";
  std::string socket;
  size_t frames = 1;
  int timeout_ms = 10000;
  bool bgra = true;
};

constexpr uint32_t kProtocolVersion = 1;

void Usage() {
  std::fprintf(stderr,
               "usage: raccoon_runner render --engine-dir DIR --assets DIR"
               " --icu FILE [--out F] [--frames N] [--timeout-ms N] [--rgba]\n"
               "       raccoon_runner serve --engine-dir DIR --assets DIR"
               " --icu FILE --socket PATH\n"
               "common: [--width N] [--height N] [--dpr X]"
               " [-- engine switches...]\n");
}

bool ParseOptions(int argc, char** argv, Options* options) {
  if (argc < 2) return false;
  options->command = argv[1];
  for (int i = 2; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--") {
      for (int j = i + 1; j < argc; ++j) options->engine.extra_args.emplace_back(argv[j]);
      break;
    }
    if (arg == "--rgba") {
      options->bgra = false;
      continue;
    }
    if (i + 1 >= argc) return false;
    const char* v = argv[++i];
    if (arg == "--engine-dir") options->engine.engine_dir = v;
    else if (arg == "--assets") options->engine.assets = v;
    else if (arg == "--icu") options->engine.icu = v;
    else if (arg == "--width") options->engine.width = std::strtoul(v, nullptr, 10);
    else if (arg == "--height") options->engine.height = std::strtoul(v, nullptr, 10);
    else if (arg == "--dpr") options->engine.pixel_ratio = std::strtod(v, nullptr);
    else if (arg == "--out") options->out = v;
    else if (arg == "--socket") options->socket = v;
    else if (arg == "--frames") options->frames = std::strtoul(v, nullptr, 10);
    else if (arg == "--timeout-ms") options->timeout_ms = std::atoi(v);
    else return false;
  }
  const bool engine_ok = !options->engine.engine_dir.empty() &&
                         !options->engine.assets.empty() &&
                         !options->engine.icu.empty();
  if (options->command == "render") return engine_ok;
  if (options->command == "serve") return engine_ok && !options->socket.empty();
  return false;
}

long MillisBetween(std::chrono::steady_clock::time_point from,
                   std::chrono::steady_clock::time_point to) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(to - from).count();
}

raccoon::EventLoop* g_loop = nullptr;
volatile std::sig_atomic_t g_stop = 0;

void OnSignal(int) {
  g_stop = 1;
  if (g_loop != nullptr) g_loop->Wake();
}

// Engine log lines go to stdout unchanged: the Flutter tool reads the VM
// service line from there.
void PrintEngineLog(const std::string&, const std::string& message) {
  std::fprintf(stdout, "%s\n", message.c_str());
  std::fflush(stdout);
}

FlutterPointerPhase ToPhase(raccoon::v1::PointerPhase phase) {
  switch (phase) {
    case raccoon::v1::POINTER_PHASE_ADD: return kAdd;
    case raccoon::v1::POINTER_PHASE_REMOVE: return kRemove;
    case raccoon::v1::POINTER_PHASE_HOVER: return kHover;
    case raccoon::v1::POINTER_PHASE_DOWN: return kDown;
    case raccoon::v1::POINTER_PHASE_MOVE: return kMove;
    case raccoon::v1::POINTER_PHASE_UP: return kUp;
    default: return kCancel;
  }
}

FlutterPointerEvent ToFlutterPointer(const raccoon::v1::PointerEvent& event,
                                     uint64_t now_micros) {
  FlutterPointerEvent out{};
  out.struct_size = sizeof(FlutterPointerEvent);
  out.phase = ToPhase(event.phase());
  out.timestamp = event.timestamp_micros() == 0 ? now_micros : event.timestamp_micros();
  out.x = event.x();
  out.y = event.y();
  out.device = event.pointer_id();
  out.device_kind = event.device() == raccoon::v1::POINTER_DEVICE_TOUCH
                        ? kFlutterPointerDeviceKindTouch
                        : kFlutterPointerDeviceKindMouse;
  out.buttons = event.buttons();
  if (event.scroll_delta_x() != 0 || event.scroll_delta_y() != 0) {
    out.signal_kind = kFlutterPointerSignalKindScroll;
    out.scroll_delta_x = event.scroll_delta_x();
    out.scroll_delta_y = event.scroll_delta_y();
  }
  return out;
}

FlutterKeyEvent ToFlutterKey(const raccoon::v1::KeyEvent& event,
                             uint64_t now_micros) {
  FlutterKeyEvent out{};
  out.struct_size = sizeof(FlutterKeyEvent);
  out.timestamp = event.timestamp_micros() == 0
                      ? static_cast<double>(now_micros)
                      : static_cast<double>(event.timestamp_micros());
  switch (event.kind()) {
    case raccoon::v1::KEY_KIND_UP: out.type = kFlutterKeyEventTypeUp; break;
    case raccoon::v1::KEY_KIND_REPEAT: out.type = kFlutterKeyEventTypeRepeat; break;
    default: out.type = kFlutterKeyEventTypeDown; break;
  }
  out.physical = event.physical();
  out.logical = event.logical();
  out.character = event.character().empty() ? nullptr : event.character().c_str();
  out.synthesized = event.synthesized();
  out.device_type = kFlutterKeyEventDeviceTypeKeyboard;
  return out;
}

int Render(const Options& options) {
  raccoon::EventLoop loop;
  raccoon::EngineHost host;
  std::string error;
  if (!host.Start(options.engine, PrintEngineLog, [&loop] { loop.Wake(); },
                  &error)) {
    std::fprintf(stderr, "raccoon_runner: %s\n", error.c_str());
    return 1;
  }
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(options.timeout_ms);
  bool reported_first = false;
  while (host.frame().FrameCount() < options.frames &&
         std::chrono::steady_clock::now() < deadline) {
    host.platform().RunDueTasks();
    if (!reported_first && host.frame().FrameCount() > 0) {
      reported_first = true;
      std::fprintf(stderr, "raccoon_runner: first frame after %ld ms\n",
                   MillisBetween(host.started(), std::chrono::steady_clock::now()));
    }
    loop.RunOnce(host.platform().MillisUntilNextTask());
  }
  std::fprintf(stderr, "raccoon_runner: %zu frames presented, %zux%zu\n",
               host.frame().FrameCount(), host.frame().width(),
               host.frame().height());
  int exit_code = 0;
  if (host.frame().WritePpm(options.out, options.bgra)) {
    std::fprintf(stderr, "raccoon_runner: wrote %s\n", options.out.c_str());
  } else {
    std::fprintf(stderr, "raccoon_runner: no frame written\n");
    exit_code = 1;
  }
  host.Shutdown();
  return exit_code;
}

int Serve(const Options& options) {
  raccoon::EventLoop loop;
  g_loop = &loop;
  std::signal(SIGINT, OnSignal);
  std::signal(SIGTERM, OnSignal);

  raccoon::EngineHost host;
  std::string error;
  if (!host.Start(options.engine, PrintEngineLog, [&loop] { loop.Wake(); },
                  &error)) {
    std::fprintf(stderr, "raccoon_runner: %s\n", error.c_str());
    return 1;
  }

  bool stop = false;
  size_t last_sent = 0;
  bool vm_sent = false;
  raccoon::RunnerServer* server_ptr = nullptr;

  raccoon::RunnerServer::Handler handler;
  handler.on_resize = [&host](const raccoon::v1::Resize& resize) {
    host.Resize(resize.width(), resize.height(),
                resize.pixel_ratio() > 0 ? resize.pixel_ratio() : 1.0);
  };
  handler.on_pointer = [&host](const raccoon::v1::PointerEvent& pointer) {
    host.SendPointer(ToFlutterPointer(pointer, host.NowMicros()));
  };
  handler.on_key = [&host](const raccoon::v1::KeyEvent& key) {
    host.SendKey(ToFlutterKey(key, host.NowMicros()));
  };
  handler.on_shutdown = [&stop] { stop = true; };
  handler.on_client_connected = [&] {
    raccoon::v1::RunnerMessage hello;
    hello.mutable_hello()->set_protocol_version(kProtocolVersion);
    server_ptr->Send(hello);
    last_sent = 0;
    vm_sent = false;
    std::fprintf(stderr, "raccoon_runner: client connected\n");
  };
  handler.on_client_disconnected = [] {
    std::fprintf(stderr, "raccoon_runner: client disconnected\n");
  };

  raccoon::RunnerServer server(loop, handler);
  server_ptr = &server;
  if (!server.Listen(options.socket, &error)) {
    std::fprintf(stderr, "raccoon_runner: %s\n", error.c_str());
    return 1;
  }
  std::fprintf(stdout, "raccoon_runner: listening on unix:%s\n",
               options.socket.c_str());
  std::fflush(stdout);

  while (!stop && g_stop == 0) {
    host.platform().RunDueTasks();
    if (server.has_client()) {
      if (!vm_sent) {
        const std::string uri = host.vm_service_uri();
        if (!uri.empty()) {
          raccoon::v1::RunnerMessage message;
          message.mutable_vm_service()->set_uri(uri);
          server.Send(message);
          vm_sent = true;
        }
      }
      raccoon::SoftwareFrame::Copy copy;
      if (host.frame().CopyLatest(&copy, last_sent)) {
        raccoon::v1::RunnerMessage message;
        raccoon::v1::Frame* frame = message.mutable_frame();
        frame->set_sequence(copy.sequence);
        frame->set_width(static_cast<uint32_t>(copy.width));
        frame->set_height(static_cast<uint32_t>(copy.height));
        frame->set_row_bytes(static_cast<uint32_t>(copy.row_bytes));
        frame->set_format(raccoon::v1::PIXEL_FORMAT_BGRA8888);
        frame->set_pixels(copy.pixels.data(), copy.pixels.size());
        frame->set_timestamp_micros(host.NowMicros());
        server.Send(message);
        last_sent = copy.sequence;
      }
    }
    loop.RunOnce(host.platform().MillisUntilNextTask());
  }

  if (server.has_client()) {
    raccoon::v1::RunnerMessage exited;
    exited.mutable_exited()->set_code(0);
    server.Send(exited);
  }
  host.Shutdown();
  std::fprintf(stderr, "raccoon_runner: stopped\n");
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  Options options;
  if (!ParseOptions(argc, argv, &options)) {
    Usage();
    return 2;
  }
  if (options.command == "render") return Render(options);
  return Serve(options);
}
