// raccoon_runner: hosts a Flutter app on the C embedder API.
//
//   raccoon_runner render --engine-dir DIR --assets DIR --icu FILE [--renderer auto|gl|metal|software] [--out F]
//   raccoon_runner serve  --engine-dir DIR --assets DIR --icu FILE --socket P
//   raccoon_runner --version

#include <unistd.h>
#if defined(__linux__)
#include <sys/prctl.h>
#endif

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "engine_host.h"
#include "glib_pump.h"
#include "event_loop.h"
#include "flutter_embedder.h"
#include "server.h"
#include "shared_buffers.h"

namespace {

// Buffers in the GPU ring: one being drawn, one on screen, one on its way
// back, and one of slack for the round trip.
constexpr size_t kGpuRing = 4;

struct Options {
  std::string command;
  raccoon::EngineOptions engine;
  std::string out = "frame.ppm";
  std::string socket;
  size_t frames = 1;
  int timeout_ms = 10000;
  bool bgra = raccoon::kSoftwareFrameIsBgra;
  // A manifest of native plugins to load (see plugins.h), or empty.
  std::string plugins;
};

constexpr uint32_t kProtocolVersion = 1;
constexpr raccoon::v1::PixelFormat kPixelFormat =
    raccoon::kSoftwareFrameIsBgra ? raccoon::v1::PIXEL_FORMAT_BGRA8888
                                  : raccoon::v1::PIXEL_FORMAT_RGBA8888;

void Usage() {
  std::fprintf(stderr,
               "usage: raccoon_runner render --engine-dir DIR --assets DIR"
               " --icu FILE [--out F] [--frames N] [--timeout-ms N] [--rgba]\n"
               "       raccoon_runner serve --engine-dir DIR --assets DIR"
               " --icu FILE --socket PATH\n"
               "       raccoon_runner --version\n"
               "common: [--width N] [--height N] [--dpr X] [--data-dir DIR] [--renderer auto|gl|metal|software]"
               " [--plugins MANIFEST]"
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
    else if (arg == "--data-dir") options->engine.data_dir = v;
    else if (arg == "--plugins") options->plugins = v;
    else if (arg == "--renderer") options->engine.renderer = v;
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

// Where the GPU buffers' descriptors are served: the runner's socket path
// with .gpu in place of .sock, so discovery, which lists .sock files, does
// not take it for a runner.
std::string GpuSocketPath(const std::string& socket) {
  const std::string suffix = ".sock";
  if (socket.size() > suffix.size() &&
      socket.compare(socket.size() - suffix.size(), suffix.size(), suffix) == 0) {
    return socket.substr(0, socket.size() - suffix.size()) + ".gpu";
  }
  return socket + ".gpu";
}

// How long the loop may sleep: until the next platform task or frame, at
// most |cap| milliseconds.
int NextWait(raccoon::EngineHost& host, int cap) {
  int wait = cap;
  for (int next : {host.platform().MillisUntilNextTask(), host.MillisUntilVsync()}) {
    if (next >= 0 && next < wait) wait = next;
  }
  return wait;
}

// Loads the plugins of |manifest|, if any, and keeps GLib pumped for them
// while the returned pump lives.
std::unique_ptr<raccoon::GlibPump> LoadPlugins(raccoon::EngineHost& host,
                                               raccoon::EventLoop& loop,
                                               const std::string& manifest) {
  if (manifest.empty()) return nullptr;
#if RACCOON_HAS_PLUGINS
  auto pump = std::make_unique<raccoon::GlibPump>(loop);
  std::string error;
  if (!host.LoadPlugins(manifest, &error)) {
    std::fprintf(stderr, "raccoon_runner: plugins: %s\n", error.c_str());
    return nullptr;
  }
  std::fprintf(stderr, "raccoon_runner: %zu plugins loaded\n", host.plugins_loaded());
  return pump;
#else
  (void)host;
  (void)loop;
  std::fprintf(stderr, "raccoon_runner: this runner was built without native plugins\n");
  return nullptr;
#endif
}

uint32_t Read32(const uint8_t* at) {
  return static_cast<uint32_t>(at[0]) | (static_cast<uint32_t>(at[1]) << 8) |
         (static_cast<uint32_t>(at[2]) << 16) | (static_cast<uint32_t>(at[3]) << 24);
}

// What the GPU socket carries, so a native client needs no protobuf: little
// endian, 'RGPU', generation, count, width, height, fourcc, modifier (64
// bits), then count pairs of stride and offset. On Linux one descriptor per
// buffer rides along, in index order; on macOS count IOSurface IDs follow
// the pairs instead, and nothing rides along.
//
// Then, ahead of each frame that has one, 'RFEN', generation, index, with
// the frame's fence riding along: signalled when the draw is done. And the
// client sends 'RREL', generation, index, fenced (1 when a fence rides
// along, signalled when its last use of the buffer is done) to give a
// buffer back.
std::vector<uint8_t> GpuSocketPayload(const raccoon::GpuBufferSet& set) {
  std::vector<uint8_t> out;
  auto put32 = [&out](uint32_t value) {
    for (int i = 0; i < 4; ++i) out.push_back(static_cast<uint8_t>(value >> (8 * i)));
  };
  auto put64 = [&out](uint64_t value) {
    for (int i = 0; i < 8; ++i) out.push_back(static_cast<uint8_t>(value >> (8 * i)));
  };
  out.insert(out.end(), {'R', 'G', 'P', 'U'});
  put32(set.generation);
  put32(static_cast<uint32_t>(set.strides.size()));
  put32(static_cast<uint32_t>(set.width));
  put32(static_cast<uint32_t>(set.height));
  put32(set.fourcc);
  put64(set.modifier);
  for (size_t i = 0; i < set.strides.size(); ++i) {
    put32(set.strides[i]);
    put32(set.offsets[i]);
  }
  for (const uint32_t id : set.surface_ids) put32(id);
  return out;
}

std::vector<uint8_t> FencePayload(const raccoon::SoftwareFrame::Gpu& gpu) {
  std::vector<uint8_t> out = {'R', 'F', 'E', 'N'};
  for (uint32_t value : {gpu.generation, static_cast<uint32_t>(gpu.index)}) {
    for (int i = 0; i < 4; ++i) out.push_back(static_cast<uint8_t>(value >> (8 * i)));
  }
  return out;
}

void FillGpuBuffers(const raccoon::GpuBufferSet& set, const std::string& socket,
                    raccoon::v1::GpuBuffers* out) {
  out->set_generation(set.generation);
  out->set_count(static_cast<uint32_t>(set.strides.size()));
  out->set_width(static_cast<uint32_t>(set.width));
  out->set_height(static_cast<uint32_t>(set.height));
  out->set_fourcc(set.fourcc);
  out->set_modifier(set.modifier);
  for (const uint32_t stride : set.strides) out->add_strides(stride);
  for (const uint32_t offset : set.offsets) out->add_offsets(offset);
  out->set_socket(socket);
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
  // RACCOON_RENDERER=gl|metal|software|auto stands in for --renderer.
  raccoon::EngineOptions engine = options.engine;
  if (const char* env = std::getenv("RACCOON_RENDERER");
      env != nullptr && engine.renderer == "auto") {
    engine.renderer = env;
  }
  if (!host.Start(engine, PrintEngineLog, [&loop] { loop.Wake(); },
                  &error)) {
    std::fprintf(stderr, "raccoon_runner: %s\n", error.c_str());
    return 1;
  }
  const auto plugins = LoadPlugins(host, loop, options.plugins);
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(options.timeout_ms);
  bool reported_first = false;
  while (host.frame().FrameCount() < options.frames &&
         std::chrono::steady_clock::now() < deadline) {
    host.platform().RunDueTasks();
    host.ServiceVsync();
    if (!reported_first && host.frame().FrameCount() > 0) {
      reported_first = true;
      std::fprintf(stderr, "raccoon_runner: first frame after %ld ms\n",
                   MillisBetween(host.started(), std::chrono::steady_clock::now()));
    }
    // An idle app posts no tasks, so never wait past the deadline.
    const long remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
                               deadline - std::chrono::steady_clock::now())
                               .count();
    const int cap = static_cast<int>(remaining < 0 ? 0 : remaining);
    loop.RunOnce(NextWait(host, cap));
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
  // RACCOON_RENDERER=gl|metal|software|auto stands in for --renderer.
  raccoon::EngineOptions engine = options.engine;
  if (const char* env = std::getenv("RACCOON_RENDERER");
      env != nullptr && engine.renderer == "auto") {
    engine.renderer = env;
  }
  if (!host.Start(engine, PrintEngineLog, [&loop] { loop.Wake(); },
                  &error)) {
    std::fprintf(stderr, "raccoon_runner: %s\n", error.c_str());
    return 1;
  }
  const auto plugins = LoadPlugins(host, loop, options.plugins);

  bool stop = false;
  size_t last_sent = 0;
  bool vm_sent = false;
  bool client_shared = false;
  std::unique_ptr<raccoon::SharedBufferPool> pool;
  // GPU buffers: the client asked for them in its hello, the set it was told
  // about on this socket, and the set whose descriptors went out on the GPU
  // socket.
  bool client_gpu = false;
  uint32_t gpu_told = 0;
  uint32_t gpu_fds_sent = 0;
  raccoon::RunnerServer* server_ptr = nullptr;
  // The active text field, to the client; a client with an input method
  // mirrors it there.
  // What became of the plugins, for a client that just arrived.
  auto SendPlugins = [&server_ptr, &host]() {
    if (server_ptr == nullptr || !server_ptr->has_client()) return;
#if RACCOON_HAS_PLUGINS
    raccoon::v1::RunnerMessage message;
    auto* plugins = message.mutable_plugins();
    for (const raccoon::PluginStatus& status : host.plugin_statuses()) {
      auto* entry = plugins->add_plugins();
      entry->set_name(status.name);
      entry->set_detail(status.detail);
      entry->set_state(
          status.state == "loaded"          ? raccoon::v1::PLUGIN_STATE_LOADED
          : status.state == "failed"        ? raccoon::v1::PLUGIN_STATE_FAILED
          : status.state == "built_nothing" ? raccoon::v1::PLUGIN_STATE_BUILT_NOTHING
          : status.state == "no_host"       ? raccoon::v1::PLUGIN_STATE_NO_HOST
          : status.state == "built_in"      ? raccoon::v1::PLUGIN_STATE_BUILT_IN
                                            : raccoon::v1::PLUGIN_STATE_UNSPECIFIED);
    }
    if (plugins->plugins_size() > 0) server_ptr->Send(message);
#endif
  };
  auto SendTextField = [&server_ptr](const raccoon::TextFieldState& state) {
    if (server_ptr == nullptr || !server_ptr->has_client()) return;
    raccoon::v1::RunnerMessage message;
    auto* field = message.mutable_text_field();
    field->set_active(state.active);
    field->set_text(state.text);
    field->set_selection_base(state.selection_base);
    field->set_selection_extent(state.selection_extent);
    field->set_composing_base(state.composing_base);
    field->set_composing_extent(state.composing_extent);
    field->set_multiline(state.multiline);
    field->set_input_action(state.input_action);
    field->set_obscure(state.obscure);
    server_ptr->Send(message);
  };
  // Platform messages waiting for the client's answer, by response id.
  std::unordered_map<uint64_t, const FlutterPlatformMessageResponseHandle*> pending;
  uint64_t next_response_id = 1;

  host.SetPlatformMessageCallback(
      [&](const std::string& channel, const uint8_t* data, size_t size,
          const FlutterPlatformMessageResponseHandle* handle) {
        if (server_ptr == nullptr || !server_ptr->has_client()) {
          host.Respond(handle, nullptr, 0);
          return;
        }
        raccoon::v1::RunnerMessage message;
        raccoon::v1::PlatformMessage* out = message.mutable_platform_message();
        out->set_channel(channel);
        out->set_data(data, size);
        if (handle != nullptr) {
          const uint64_t id = next_response_id++;
          pending[id] = handle;
          out->set_response_id(id);
        }
        if (!server_ptr->Send(message) && handle != nullptr) {
          pending.erase(out->response_id());
          host.Respond(handle, nullptr, 0);
        }
      });

  raccoon::RunnerServer::Handler handler;
  handler.on_resize = [&host](const raccoon::v1::Resize& resize) {
    if (std::getenv("RACCOON_TRACE") != nullptr) {
      std::fprintf(stderr, "raccoon_runner: resize %ux%u @%.2f\n", resize.width(),
                   resize.height(), resize.pixel_ratio());
    }
    host.Resize(resize.width(), resize.height(),
                resize.pixel_ratio() > 0 ? resize.pixel_ratio() : 1.0);
  };
  // RACCOON_TRACE=1 prints what the client sends, for debugging a client.
  const bool trace = std::getenv("RACCOON_TRACE") != nullptr;
  handler.on_pointer = [&host, trace](const raccoon::v1::PointerEvent& pointer) {
    if (trace) {
      std::fprintf(stderr, "raccoon_runner: pointer phase=%d x=%.1f y=%.1f buttons=%lld device=%d\n",
                   static_cast<int>(pointer.phase()), pointer.x(), pointer.y(),
                   static_cast<long long>(pointer.buttons()), pointer.pointer_id());
    }
    host.SendPointer(ToFlutterPointer(pointer, host.NowMicros()));
  };
  handler.on_key = [&host, trace](const raccoon::v1::KeyEvent& key) {
    if (trace) {
      std::fprintf(stderr, "raccoon_runner: key kind=%d logical=%llx character=%s\n",
                   static_cast<int>(key.kind()),
                   static_cast<unsigned long long>(key.logical()),
                   key.character().c_str());
    }
    host.SendKey(ToFlutterKey(key, host.NowMicros()));
  };
  handler.on_shutdown = [&stop] { stop = true; };
  // The Flutter tool started this runner; when it is gone, so is the run.
  const pid_t parent = getppid();
  handler.on_hello = [&](const raccoon::v1::ClientHello& hello) {
    client_shared = hello.shared_buffers();
    client_gpu = false;
    if (hello.gpu_buffers()) {
      std::string gpu_error;
      if (host.EnableGpuBuffers(kGpuRing, &gpu_error)) {
        client_gpu = true;
      } else {
        std::fprintf(stderr, "raccoon_runner: no GPU buffers: %s; frames by readback\n",
                     gpu_error.c_str());
      }
    }
    gpu_told = 0;
    host.text_input().SetComposer(hello.composes());
    // A client that arrives mid-run learns which field is active.
    SendTextField(host.text_input().state());
    SendPlugins();
  };
  handler.on_text_editing = [&host](const raccoon::v1::TextEditing& editing) {
    host.text_input().ApplyEditing(editing.text(), editing.selection_base(),
                                   editing.selection_extent(),
                                   editing.composing_base(),
                                   editing.composing_extent());
  };
  host.text_input().SetStateListener(
      [&](const raccoon::TextFieldState& state) { SendTextField(state); });
  handler.on_release_buffer = [&](const raccoon::v1::ReleaseBuffer& release) {
    if (release.generation() != 0) {
      host.ReleaseGpuBuffer(release.generation(), static_cast<int>(release.index()));
      return;
    }
    if (pool) pool->Release(static_cast<int>(release.index()));
  };
  handler.on_platform_response = [&](const raccoon::v1::PlatformResponse& response) {
    const auto found = pending.find(response.response_id());
    if (found == pending.end()) return;
    const FlutterPlatformMessageResponseHandle* handle = found->second;
    pending.erase(found);
    if (response.handled()) {
      host.Respond(handle,
                   reinterpret_cast<const uint8_t*>(response.data().data()),
                   response.data().size());
    } else {
      host.Respond(handle, nullptr, 0);
    }
  };
  handler.on_client_connected = [&] {
    raccoon::v1::RunnerMessage hello;
    hello.mutable_hello()->set_protocol_version(kProtocolVersion);
    hello.mutable_hello()->set_pid(static_cast<uint32_t>(getpid()));
    server_ptr->Send(hello);
    last_sent = 0;
    vm_sent = false;
    std::fprintf(stderr, "raccoon_runner: client connected\n");
  };
  handler.on_client_disconnected = [&] {
    host.text_input().SetComposer(false);
    // Nobody will answer these now; let the app see "no plugin".
    for (const auto& [id, handle] : pending) host.Respond(handle, nullptr, 0);
    pending.clear();
    host.frame().SetSharedPool(nullptr);
    pool.reset();
    client_shared = false;
    host.DisableGpuBuffers();
    client_gpu = false;
    gpu_told = 0;
    std::fprintf(stderr, "raccoon_runner: client disconnected\n");
  };

  raccoon::RunnerServer server(loop, handler);
  server_ptr = &server;
  if (!server.Listen(options.socket, &error)) {
    std::fprintf(stderr, "raccoon_runner: %s\n", error.c_str());
    return 1;
  }
  // The GPU socket: a native client takes the buffers' descriptors here,
  // which Dart cannot. Named without .sock, so discovery does not list it.
  const std::string gpu_socket = GpuSocketPath(options.socket);
  raccoon::RunnerServer::Handler gpu_handler;
  gpu_handler.on_client_connected = [&] { gpu_fds_sent = 0; };
  gpu_handler.on_client_disconnected = [&] {
    gpu_fds_sent = 0;
    // Whatever it held, nothing samples now.
    host.ReleaseAllGpuBuffers();
  };
  gpu_handler.on_raw = [&](const uint8_t* payload, size_t size, std::vector<int>& fds) {
    if (size >= 16 && std::memcmp(payload, "RREL", 4) == 0) {
      int fence = -1;
      if (Read32(payload + 12) != 0 && !fds.empty()) {
        fence = fds.front();
        fds.erase(fds.begin());
      }
      host.ReleaseGpuBuffer(Read32(payload + 4), static_cast<int>(Read32(payload + 8)),
                            fence);
      return;
    }
    // Not a message this runner knows: whatever it brought is let go.
    for (int fd : fds) close(fd);
    fds.clear();
  };
  raccoon::RunnerServer gpu_server(loop, gpu_handler);
  if (!gpu_server.Listen(gpu_socket, &error)) {
    std::fprintf(stderr, "raccoon_runner: %s\n", error.c_str());
    return 1;
  }
  std::fprintf(stdout, "raccoon_runner: listening on unix:%s\n",
               options.socket.c_str());
  std::fflush(stdout);

  while (!stop && g_stop == 0) {
    host.platform().RunDueTasks();
    host.ServiceVsync();
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
      if (client_gpu) {
        raccoon::GpuBufferSet set;
        if (host.GpuBufferSetNow(&set)) {
          if (set.generation != gpu_told) {
            raccoon::v1::RunnerMessage message;
            FillGpuBuffers(set, gpu_socket, message.mutable_gpu_buffers());
            if (server.Send(message)) gpu_told = set.generation;
          }
          if (gpu_server.has_client() && set.generation != gpu_fds_sent) {
            if (gpu_server.SendBytesWithFds(GpuSocketPayload(set), set.fds)) {
              gpu_fds_sent = set.generation;
            }
          }
        }
        raccoon::SoftwareFrame::Gpu gpu;
        if (host.frame().TakeGpu(&gpu)) {
          // The fence goes first, to a client holding this set's buffers.
          if (gpu.fence_fd >= 0) {
            if (gpu_server.has_client() && gpu_fds_sent == gpu.generation) {
              gpu_server.SendBytesWithFds(FencePayload(gpu), {gpu.fence_fd});
            }
            close(gpu.fence_fd);
          }
          raccoon::v1::RunnerMessage message;
          auto* frame = message.mutable_frame();
          frame->set_sequence(gpu.sequence);
          frame->set_width(static_cast<uint32_t>(gpu.width));
          frame->set_height(static_cast<uint32_t>(gpu.height));
          frame->set_row_bytes(static_cast<uint32_t>(gpu.width * 4));
          frame->set_format(raccoon::v1::PIXEL_FORMAT_UNSPECIFIED);
          frame->set_in_gpu_buffer(true);
          frame->set_buffer_index(static_cast<uint32_t>(gpu.index));
          frame->set_gpu_generation(gpu.generation);
          frame->set_timestamp_micros(host.NowMicros());
          if (!server.Send(message)) host.ReleaseGpuBuffer(gpu.generation, gpu.index);
          last_sent = gpu.sequence;
        }
      }
      raccoon::SoftwareFrame::Shared shared;
      if (host.frame().TakeShared(&shared)) {
        raccoon::v1::RunnerMessage message;
        raccoon::v1::Frame* frame = message.mutable_frame();
        frame->set_sequence(shared.sequence);
        frame->set_width(static_cast<uint32_t>(shared.width));
        frame->set_height(static_cast<uint32_t>(shared.height));
        frame->set_row_bytes(static_cast<uint32_t>(shared.row_bytes));
        frame->set_format(kPixelFormat);
        frame->set_in_shared_buffer(true);
        frame->set_buffer_index(static_cast<uint32_t>(shared.index));
        frame->set_timestamp_micros(host.NowMicros());
        if (!server.Send(message) && pool) pool->Release(shared.index);
        last_sent = shared.sequence;
      }
      raccoon::SoftwareFrame::Copy copy;
      if (host.frame().CopyLatest(&copy, last_sent)) {
        raccoon::v1::RunnerMessage message;
        raccoon::v1::Frame* frame = message.mutable_frame();
        frame->set_sequence(copy.sequence);
        frame->set_width(static_cast<uint32_t>(copy.width));
        frame->set_height(static_cast<uint32_t>(copy.height));
        frame->set_row_bytes(static_cast<uint32_t>(copy.row_bytes));
        frame->set_format(kPixelFormat);
        frame->set_pixels(copy.pixels.data(), copy.pixels.size());
        frame->set_timestamp_micros(host.NowMicros());
        server.Send(message);
        last_sent = copy.sequence;
      }
      // Resize the shared buffers only after the pending frame went out:
      // replacing the pool releases it, and that frame would be lost.
      // Shared buffers, sized for the current frame; replaced on resize.
      const size_t need = host.frame().LatestSizeBytes();
      if (client_shared && !client_gpu && need > 0 &&
          (!pool || pool->size() != need)) {
        host.frame().SetSharedPool(nullptr);
        auto fresh = std::make_unique<raccoon::SharedBufferPool>();
        std::string pool_error;
        if (fresh->Allocate(2, need, &pool_error)) {
          raccoon::v1::RunnerMessage message;
          message.mutable_shared_buffers()->set_count(2);
          message.mutable_shared_buffers()->set_size(need);
          if (server.SendWithFds(message, fresh->fds())) {
            pool = std::move(fresh);
            host.frame().SetSharedPool(pool.get());
          }
        } else {
          std::fprintf(stderr, "raccoon_runner: %s; frames stay inline\n",
                       pool_error.c_str());
          client_shared = false;
        }
      }
    }
    if (getppid() != parent) {
      std::fprintf(stderr, "raccoon_runner: parent %d is gone; stopping\n",
                   static_cast<int>(parent));
      stop = true;
    }
    loop.RunOnce(NextWait(host, 1000));
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
#if defined(__linux__)
  // RACCOON_PTRACE_ANY=1 lets any process of this user attach a debugger,
  // for a backtrace of a runner that a test harness started.
  if (std::getenv("RACCOON_PTRACE_ANY") != nullptr) {
    prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
  }
#endif
  if (argc == 2 && std::strcmp(argv[1], "--version") == 0) {
    std::printf("%s\n", RACCOON_RUNNER_VERSION);
    return 0;
  }
  Options options;
  if (!ParseOptions(argc, argv, &options)) {
    Usage();
    return 2;
  }
  if (options.command == "render") return Render(options);
  return Serve(options);
}
