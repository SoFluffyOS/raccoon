// raccoon_runner: hosts a Flutter app on the C embedder API.
//
//   raccoon_runner render --engine-dir DIR --assets DIR --icu FILE [--renderer auto|gl|metal|vulkan|software] [--out F]
//   raccoon_runner serve  --engine-dir DIR --assets DIR --icu FILE --socket P
//   raccoon_runner --version

#include <signal.h>
#if defined(_WIN32)
#include <io.h>
#include <windows.h>
#include <timeapi.h>
#include <tlhelp32.h>
// A windows.h macro that would rename the embedder's GetCurrentTime.
#undef GetCurrentTime
#else
#include <unistd.h>
#endif
#if defined(__linux__)
#include <sys/prctl.h>
#endif

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "engine_host.h"
#include "glib_pump.h"
#include "message_pump.h"
#include "run_loop_pump.h"
#include "event_loop.h"
#include "flutter_embedder.h"
#include "server.h"
#include "shared_buffers.h"
#if RACCOON_HAS_METAL
#include "surface_port_server.h"
#endif
#include "stderr_capture.h"

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

// How long the client may take to answer a platform message before the app
// gets "no plugin" instead: a reply that never comes must not hang it.
constexpr auto kReplyTimeout = std::chrono::seconds(5);
const std::string kNoReplyWhy =
    "the client did not answer in " + std::to_string(kReplyTimeout.count()) + " s";

// The log lines kept from before the first frame, the latest, for a client
// that arrives after them: an app that dies in main() has said why by then.
constexpr size_t kStartupLines = 200;

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
               "common: [--width N] [--height N] [--dpr X] [--data-dir DIR] [--renderer auto|gl|metal|vulkan|software]"
               " [--plugins MANIFEST] [--camera-source PNG|JPEG]"
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
    else if (arg == "--camera-source") options->engine.camera_source = v;
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

// When the process started, near enough: before main, as globals are made.
const auto kLaunched = std::chrono::steady_clock::now();

long MillisBetween(std::chrono::steady_clock::time_point from,
                   std::chrono::steady_clock::time_point to) {
  return static_cast<long>(
      std::chrono::duration_cast<std::chrono::milliseconds>(to - from).count());
}

raccoon::EventLoop* g_loop = nullptr;
volatile std::sig_atomic_t g_stop = 0;

void OnSignal(int) {
  g_stop = 1;
  if (g_loop != nullptr) g_loop->Wake();
}

#if defined(_WIN32)

uint32_t ThisProcessId() { return GetCurrentProcessId(); }

// The runner's ancestors whose end ends the run, nearest first: its parent,
// and on through Git Bash's processes to the first that is not one. Windows
// has no getppid, so they are found once, in a snapshot of the process
// table. The device helper runs in Git Bash, where the tool starts a
// launcher, the launcher the shell, and a forked copy of the shell waits
// on the runner; the tool stops a run by killing the launcher, which none
// of the others notice, and the shell has no pid of the tool to pass on.
std::vector<uint32_t> AncestorsToWatch() {
  struct Entry {
    uint32_t parent;
    std::string exe;
  };
  std::unordered_map<uint32_t, Entry> table;
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return {};
  PROCESSENTRY32 entry{};
  entry.dwSize = sizeof(entry);
  for (BOOL more = Process32First(snapshot, &entry); more;
       more = Process32Next(snapshot, &entry)) {
    std::string exe = entry.szExeFile;
    for (char& c : exe) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    table[entry.th32ProcessID] = {entry.th32ParentProcessID, exe};
  }
  CloseHandle(snapshot);
  std::vector<uint32_t> ancestors;
  uint32_t pid = GetCurrentProcessId();
  // A bound, in case a reused pid makes a loop of the table.
  for (int depth = 0; depth < 16; ++depth) {
    const auto found = table.find(pid);
    if (found == table.end() || found->second.parent == 0) break;
    pid = found->second.parent;
    ancestors.push_back(pid);
    const auto parent = table.find(pid);
    if (parent == table.end() ||
        (parent->second.exe != "bash.exe" && parent->second.exe != "sh.exe")) {
      break;
    }
  }
  return ancestors;
}

// Says when a process has exited. Its handle is opened up front, so a pid
// the system hands out again later is not taken for it.
class ProcessWatch {
 public:
  // A pid of 0 or 1 is no process, as on the other hosts.
  explicit ProcessWatch(uint32_t pid) : pid_(pid) {
    if (pid <= 1) return;
    handle_ = OpenProcess(SYNCHRONIZE, FALSE, pid);
    gone_ = handle_ == nullptr && GetLastError() == ERROR_INVALID_PARAMETER;
  }
  ~ProcessWatch() {
    if (handle_ != nullptr) CloseHandle(handle_);
  }
  ProcessWatch(const ProcessWatch&) = delete;
  ProcessWatch& operator=(const ProcessWatch&) = delete;

  uint32_t pid() const { return pid_; }
  bool Exited() const {
    return gone_ || (handle_ != nullptr && WaitForSingleObject(handle_, 0) == WAIT_OBJECT_0);
  }

 private:
  uint32_t pid_;
  HANDLE handle_ = nullptr;
  bool gone_ = false;
};

#else

uint32_t ThisProcessId() { return static_cast<uint32_t>(getpid()); }

#endif

// Engine log lines go to stdout unchanged: the Flutter tool reads the VM
// service line from there.
void PrintEngineLog(const std::string&, const std::string& message) {
  std::fprintf(stdout, "%s\n", message.c_str());
  std::fflush(stdout);
}

// Log lines on their way to the client: the engine's, from its thread, and
// stderr's, from the capture's. The loop takes them.
class LogQueue {
 public:
  explicit LogQueue(raccoon::EventLoop& loop) : loop_(loop) {}

  void Push(const std::string& tag, const std::string& message) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      lines_.emplace_back(tag, message);
    }
    loop_.Wake();
  }

  std::vector<std::pair<std::string, std::string>> Take() {
    std::lock_guard<std::mutex> lock(mutex_);
    return std::exchange(lines_, {});
  }

 private:
  raccoon::EventLoop& loop_;
  std::mutex mutex_;
  std::vector<std::pair<std::string, std::string>> lines_;
};

// |text| with every byte that is not part of valid UTF-8 replaced by '?':
// protobuf strings must be UTF-8, and a plugin may print anything.
std::string ValidUtf8(const std::string& text) {
  std::string out;
  out.reserve(text.size());
  size_t i = 0;
  while (i < text.size()) {
    // The sequence's length, from its lead byte; 0 for a byte that leads
    // none.
    const auto lead = static_cast<unsigned char>(text[i]);
    size_t length = 0;
    if (lead < 0x80) length = 1;
    else if ((lead >> 5) == 0x6) length = 2;
    else if ((lead >> 4) == 0xE) length = 3;
    else if ((lead >> 3) == 0x1E) length = 4;
    bool ok = length > 0 && i + length <= text.size();
    for (size_t k = 1; ok && k < length; ++k) {
      ok = (static_cast<unsigned char>(text[i + k]) >> 6) == 0x2;
    }
    if (!ok) {
      out.push_back('?');
      ++i;
      continue;
    }
    out.append(text, i, length);
    i += length;
  }
  return out;
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
  for (int next : {host.platform().MillisUntilNextTask(), host.MillisUntilVsync(),
                   host.MillisUntilCamera()}) {
    if (next >= 0 && next < wait) wait = next;
  }
  return wait;
}

// What plugins' main loop is: GLib's on Linux, the main run loop on macOS,
// the thread's Win32 messages on Windows.
#if defined(__APPLE__)
using PluginPump = raccoon::RunLoopPump;
#elif defined(_WIN32)
using PluginPump = raccoon::MessagePump;
#else
using PluginPump = raccoon::GlibPump;
#endif

// Loads the plugins of |manifest|, if any, and keeps their main loop turning
// while the returned pump lives.
std::unique_ptr<PluginPump> LoadPlugins(raccoon::EngineHost& host, raccoon::EventLoop& loop,
                                        const std::string& manifest) {
  if (manifest.empty()) return nullptr;
#if RACCOON_HAS_PLUGINS
  auto pump = std::make_unique<PluginPump>(loop);
  std::string error;
  if (!host.LoadPlugins(manifest, &error)) {
    std::fprintf(stderr, "🦝 plugins: %s\n", error.c_str());
    return nullptr;
  }
  std::fprintf(stderr, "🦝 %zu plugins loaded\n", host.plugins_loaded());
  return pump;
#else
  (void)host;
  (void)loop;
  std::fprintf(stderr, "🦝 this runner was built without native plugins\n");
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
//
// macOS: a client that takes surfaces by Mach port sends 'RPRT'. The runner
// answers 'RSVC', the length of a Mach service name, the name, then a
// 16-byte token, and announces the ring in use again; the client asks that
// service for each set's surfaces (surface_port_server.h), and once an ask
// has reached it the rings are built without global surfaces. A client
// that never sends 'RPRT', or never reaches the service, keeps looking
// surfaces up by ID.
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
    case raccoon::v1::POINTER_PHASE_PAN_ZOOM_START: return kPanZoomStart;
    case raccoon::v1::POINTER_PHASE_PAN_ZOOM_UPDATE: return kPanZoomUpdate;
    case raccoon::v1::POINTER_PHASE_PAN_ZOOM_END: return kPanZoomEnd;
    // Named, and any phase this runner doesn't know: both a cancel.
    case raccoon::v1::POINTER_PHASE_CANCEL:
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
  switch (event.device()) {
    case raccoon::v1::POINTER_DEVICE_TOUCH: out.device_kind = kFlutterPointerDeviceKindTouch; break;
    case raccoon::v1::POINTER_DEVICE_TRACKPAD: out.device_kind = kFlutterPointerDeviceKindTrackpad; break;
    default: out.device_kind = kFlutterPointerDeviceKindMouse; break;
  }
  out.buttons = event.buttons();
  // A gesture's pan, scale and rotation; a scale of 0 was never meant.
  out.pan_x = event.pan_x();
  out.pan_y = event.pan_y();
  out.scale = event.scale() == 0 ? 1.0 : event.scale();
  out.rotation = event.rotation();
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
    std::fprintf(stderr, "🦝 %s\n", error.c_str());
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
    host.ServiceCamera();
    if (!reported_first && host.frame().FrameCount() > 0) {
      reported_first = true;
      std::fprintf(stderr, "🦝 first frame after %ld ms\n",
                   MillisBetween(host.started(), std::chrono::steady_clock::now()));
    }
    // An idle app posts no tasks, so never wait past the deadline.
    const long remaining = MillisBetween(std::chrono::steady_clock::now(), deadline);
    const int cap = static_cast<int>(remaining < 0 ? 0 : remaining);
    loop.RunOnce(NextWait(host, cap));
  }
  std::fprintf(stderr, "🦝 %zu frames presented, %zux%zu\n",
               host.frame().FrameCount(), host.frame().width(),
               host.frame().height());
  int exit_code = 0;
  if (host.frame().WritePpm(options.out, options.bgra)) {
    std::fprintf(stderr, "🦝 wrote %s\n", options.out.c_str());
  } else {
    std::fprintf(stderr, "🦝 no frame written\n");
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
#if defined(_WIN32)
  std::signal(SIGBREAK, OnSignal);
#endif

  // What package:raccoon's Raccoon().isPresent reads. Set before any thread
  // starts, since setenv races getenv.
  const std::string endpoint = "unix:" + options.socket;
#if defined(_WIN32)
  _putenv_s("RACCOON_ENDPOINT", endpoint.c_str());
#else
  setenv("RACCOON_ENDPOINT", endpoint.c_str(), 1);
#endif

  // The app's log reaches the client too: the engine's lines, and stderr,
  // where the engine prints what main() died of and the runner what went
  // unanswered. A client is often not there yet when that happens.
  LogQueue logs(loop);
  raccoon::StderrCapture capture;
  if (!capture.Start([&logs](const std::string& line) { logs.Push("stderr", line); })) {
    std::fprintf(stderr, "🦝 stderr stays the client's blind spot\n");
  }

  raccoon::EngineHost host;
  std::string error;
  // RACCOON_RENDERER=gl|metal|software|auto stands in for --renderer.
  raccoon::EngineOptions engine = options.engine;
  if (const char* env = std::getenv("RACCOON_RENDERER");
      env != nullptr && engine.renderer == "auto") {
    engine.renderer = env;
  }
  auto on_log = [&logs](const std::string& tag, const std::string& message) {
    PrintEngineLog(tag, message);
    logs.Push(tag, message);
  };
  if (!host.Start(engine, on_log, [&loop] { loop.Wake(); }, &error)) {
    std::fprintf(stderr, "🦝 %s\n", error.c_str());
    return 1;
  }
  const auto plugins = LoadPlugins(host, loop, options.plugins);

  bool stop = false;
  size_t last_sent = 0;
  bool frames_held = false;
  bool vm_sent = false;
  bool client_shared = false;
  std::unique_ptr<raccoon::SharedBufferPool> pool;
  // Which set pool is, as the client was told (#135).
  uint32_t shared_generation = 0;
  // GPU buffers: the client asked for them in its hello, the set it was told
  // about on this socket, and the set whose descriptors went out on the GPU
  // socket.
  bool client_gpu = false;
  uint32_t gpu_told = 0;
  uint32_t gpu_fds_sent = 0;
  raccoon::RunnerServer* server_ptr = nullptr;
  // The GPU socket's server, set once it exists below.
  raccoon::RunnerServer* gpu_server_ptr = nullptr;
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
  // Platform messages waiting for the client's answer, by response id,
  // with when the app gets "no plugin" instead.
  struct Pending {
    const FlutterPlatformMessageResponseHandle* handle;
    std::string channel;
    std::chrono::steady_clock::time_point deadline;
  };
  std::unordered_map<uint64_t, Pending> pending;
  uint64_t next_response_id = 1;

  host.SetPlatformMessageCallback(
      [&](const std::string& channel, const uint8_t* data, size_t size,
          const FlutterPlatformMessageResponseHandle* handle) {
        if (server_ptr == nullptr || !server_ptr->has_client()) {
          host.RespondNoPlugin(channel, handle, "no client");
          return;
        }
        raccoon::v1::RunnerMessage message;
        raccoon::v1::PlatformMessage* out = message.mutable_platform_message();
        out->set_channel(channel);
        out->set_data(data, size);
        if (handle != nullptr) {
          const uint64_t id = next_response_id++;
          pending[id] = {handle, channel, std::chrono::steady_clock::now() + kReplyTimeout};
          out->set_response_id(id);
        }
        // A send that fails closes the client, and closing answers what is
        // pending, this one included: answered twice, the engine's handle
        // would be used after it freed it (#138).
        if (!server_ptr->Send(message) && handle != nullptr &&
            pending.erase(out->response_id()) == 1) {
          host.RespondNoPlugin(channel, handle, "no client");
        }
      });
  // Answers what the client left too long; how long the loop may sleep
  // before the next one is due, at most |cap|.
  auto ExpireReplies = [&](int cap) {
    const auto now = std::chrono::steady_clock::now();
    int wait = cap;
    for (auto it = pending.begin(); it != pending.end();) {
      if (it->second.deadline <= now) {
        host.RespondNoPlugin(it->second.channel, it->second.handle, kNoReplyWhy.c_str());
        it = pending.erase(it);
        continue;
      }
      const long left = MillisBetween(now, it->second.deadline) + 1;
      if (left < wait) wait = static_cast<int>(left);
      ++it;
    }
    return wait;
  };

  // The lines from before the first frame, for a client that comes later.
  std::deque<raccoon::v1::RunnerMessage> startup_lines;
  bool startup_over = false;
  auto SendLogs = [&]() {
    for (auto& [tag, text] : logs.Take()) {
      raccoon::v1::RunnerMessage message;
      message.mutable_log()->set_tag(ValidUtf8(tag));
      message.mutable_log()->set_message(ValidUtf8(text));
      if (server_ptr != nullptr && server_ptr->has_client()) server_ptr->Send(message);
      if (startup_over) continue;
      startup_lines.push_back(std::move(message));
      if (startup_lines.size() > kStartupLines) startup_lines.pop_front();
    }
    if (!startup_over && host.frame().FrameCount() > 0) {
      startup_over = true;
      startup_lines.clear();
      std::fprintf(stderr, "🦝 first frame %ld ms after launch\n",
                   MillisBetween(kLaunched, std::chrono::steady_clock::now()));
    }
  };

  raccoon::RunnerServer::Handler handler;
  handler.on_resize = [&host](const raccoon::v1::Resize& resize) {
    if (std::getenv("RACCOON_TRACE") != nullptr) {
      std::fprintf(stderr, "🦝 resize %ux%u @%.2f\n", resize.width(),
                   resize.height(), resize.pixel_ratio());
    }
    host.Resize(resize.width(), resize.height(),
                resize.pixel_ratio() > 0 ? resize.pixel_ratio() : 1.0);
  };
  // RACCOON_TRACE=1 prints what the client sends, for debugging a client.
  const bool trace = std::getenv("RACCOON_TRACE") != nullptr;
  handler.on_pointer = [&host, trace](const raccoon::v1::PointerEvent& pointer) {
    if (trace) {
      std::fprintf(stderr, "🦝 pointer phase=%d x=%.1f y=%.1f buttons=%lld device=%d\n",
                   static_cast<int>(pointer.phase()), pointer.x(), pointer.y(),
                   static_cast<long long>(pointer.buttons()), pointer.pointer_id());
    }
    host.SendPointer(ToFlutterPointer(pointer, host.NowMicros()));
  };
  handler.on_key = [&host, trace](const raccoon::v1::KeyEvent& key) {
    if (trace) {
      std::fprintf(stderr, "🦝 key kind=%d logical=%llx character=%s\n",
                   static_cast<int>(key.kind()),
                   static_cast<unsigned long long>(key.logical()),
                   key.character().c_str());
    }
    host.SendKey(ToFlutterKey(key, host.NowMicros()));
  };
  handler.on_shutdown = [&stop] { stop = true; };
  // The Flutter tool started this runner; when it is gone, so is the run.
  // Through the device helper, the helper is the parent and
  // RACCOON_PARENT_PID names the tool. On Windows the runner watches its
  // ancestors through Git Bash instead (see AncestorsToWatch), and the
  // variable too where it names a process.
  const char* tool_env = std::getenv("RACCOON_PARENT_PID");
#if defined(_WIN32)
  std::vector<std::unique_ptr<ProcessWatch>> watches;
  for (const uint32_t pid : AncestorsToWatch()) {
    watches.push_back(std::make_unique<ProcessWatch>(pid));
  }
  if (tool_env != nullptr) {
    watches.push_back(std::make_unique<ProcessWatch>(static_cast<uint32_t>(std::atoi(tool_env))));
  }
  // The pid that is gone, or 0.
  auto GonePid = [&watches]() -> int {
    for (const auto& watch : watches) {
      if (watch->Exited()) return static_cast<int>(watch->pid());
    }
    return 0;
  };
#else
  const pid_t parent = getppid();
  const pid_t tool = tool_env == nullptr ? 0 : static_cast<pid_t>(std::atoi(tool_env));
  auto GonePid = [parent, tool]() -> int {
    if (getppid() != parent) return static_cast<int>(parent);
    return tool > 1 && kill(tool, 0) != 0 && errno == ESRCH ? static_cast<int>(tool) : 0;
  };
#endif
  handler.on_hello = [&](const raccoon::v1::ClientHello& hello) {
    client_shared = hello.shared_buffers();
    // A client that says hello again without shared buffers, one whose set
    // came short of its descriptors, takes frames inline from here (#145).
    if (!client_shared && pool) {
      host.frame().SetSharedPool(nullptr);
      pool.reset();
    }
    client_gpu = false;
    if (hello.gpu_buffers()) {
      std::string gpu_error;
      if (host.EnableGpuBuffers(kGpuRing, &gpu_error)) {
        client_gpu = true;
      } else {
        std::fprintf(stderr, "🦝 no GPU buffers: %s; frames by readback\n",
                     gpu_error.c_str());
      }
    }
    // A client that says hello again without GPU buffers takes pixels.
    if (!client_gpu) host.DisableGpuBuffers();
    gpu_told = 0;
    host.text_input().SetComposer(hello.composes());
    // A client that arrives mid-run learns which field is active.
    SendTextField(host.text_input().state());
    SendPlugins();
    // Its own first frame: after a client that took frames as GPU buffers,
    // the latest is in one, and an idle app sends no other.
    host.Redraw();
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
    // A release meant for a set since replaced would free the same index
    // in this one while its frame is read; 0 is a client that predates it.
    const uint32_t meant_for = release.shared_generation();
    if (meant_for != 0 && meant_for != shared_generation) return;
    if (pool) pool->Release(static_cast<int>(release.index()));
  };
  handler.on_platform_response = [&](const raccoon::v1::PlatformResponse& response) {
    const auto found = pending.find(response.response_id());
    if (found == pending.end()) return;
    const Pending waiting = std::move(found->second);
    pending.erase(found);
    if (response.handled()) {
      host.Respond(waiting.handle,
                   reinterpret_cast<const uint8_t*>(response.data().data()),
                   response.data().size());
    } else {
      host.RespondNoPlugin(waiting.channel, waiting.handle, "the client has no handler");
    }
  };
  handler.on_client_connected = [&] {
    raccoon::v1::RunnerMessage hello;
    hello.mutable_hello()->set_protocol_version(kProtocolVersion);
    hello.mutable_hello()->set_pid(ThisProcessId());
    server_ptr->Send(hello);
    // What the app said before it drew anything, why it stopped if it did.
    for (const auto& line : startup_lines) server_ptr->Send(line);
    last_sent = 0;
    vm_sent = false;
    std::fprintf(stderr, "🦝 client connected\n");
  };
  handler.on_client_disconnected = [&] {
    host.text_input().SetComposer(false);
    // Nobody will answer these now; let the app see "no plugin".
    for (const auto& [id, waiting] : pending) {
      host.RespondNoPlugin(waiting.channel, waiting.handle, "the client went away");
    }
    pending.clear();
    host.frame().SetSharedPool(nullptr);
    pool.reset();
    client_shared = false;
    host.DisableGpuBuffers();
    client_gpu = false;
    gpu_told = 0;
    // Its GPU socket goes with it: kept, it would refuse the next client's
    // and take that client's buffers and fences (#144).
    if (gpu_server_ptr != nullptr) gpu_server_ptr->Disconnect();
    std::fprintf(stderr, "🦝 client disconnected\n");
  };

  raccoon::RunnerServer server(loop, handler);
  server_ptr = &server;
  if (!server.Listen(options.socket, &error)) {
    std::fprintf(stderr, "🦝 %s\n", error.c_str());
    // The engine runs already: its threads post to objects about to go.
    host.Shutdown();
    return 1;
  }
  // The GPU socket: a native client takes the buffers' descriptors here,
  // which Dart cannot. Named without .sock, so discovery does not list it.
  const std::string gpu_socket = GpuSocketPath(options.socket);
#if RACCOON_HAS_METAL
  // Set once the GPU socket's server exists, below.
  std::function<void()> SharePorts;
  // A request with the token reached the service: the client can take
  // surfaces by port, so the ring stops being global. Until then a client
  // whose lookup fails still sees global surfaces by ID.
  std::atomic<bool> ports_asked{false};
#endif
  raccoon::RunnerServer::Handler gpu_handler;
  gpu_handler.on_client_connected = [&] { gpu_fds_sent = 0; };
  gpu_handler.on_client_disconnected = [&] {
    gpu_fds_sent = 0;
    // Whatever it held, nothing samples now.
    host.ReleaseAllGpuBuffers();
#if RACCOON_HAS_METAL
    // The next client may not ask for ports.
    ports_asked = false;
    host.ShareGpuBuffersByPort(false);
#endif
  };
  gpu_handler.on_raw = [&](const uint8_t* payload, size_t size, std::vector<int>& fds) {
#if RACCOON_HAS_METAL
    if (size >= 4 && std::memcmp(payload, "RPRT", 4) == 0) {
      SharePorts();
      return;
    }
#endif
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
  gpu_server_ptr = &gpu_server;
#if RACCOON_HAS_METAL
  // Surfaces by Mach port, for a client that asks: the service starts at the
  // first ask and stays; each ask gets its name and a token of its own.
  raccoon::SurfacePortServer ports;
  SharePorts = [&] {
    std::string why;
    const bool started = ports.Start(
        [&host, &loop, &ports_asked](uint32_t generation, std::vector<uint32_t>* out) {
          ports_asked = true;
          loop.Wake();
          return host.GpuBufferPorts(generation, out);
        },
        &why);
    if (!started || !host.can_share_gpu_buffers_by_port()) {
      std::fprintf(stderr, "🦝 no surfaces by port (%s); by ID as before\n",
                   started ? "no Metal renderer" : why.c_str());
      return;
    }
    std::vector<uint8_t> answer = {'R', 'S', 'V', 'C'};
    const uint32_t length = static_cast<uint32_t>(ports.name().size());
    for (int i = 0; i < 4; ++i) answer.push_back(static_cast<uint8_t>(length >> (8 * i)));
    answer.insert(answer.end(), ports.name().begin(), ports.name().end());
    const auto token = ports.RenewToken();
    answer.insert(answer.end(), token.begin(), token.end());
    gpu_server.SendBytesWithFds(answer, {});
    // The ring in use again, global still: the client asks the service for
    // it, and that ask turns the next ring's surfaces private.
    gpu_fds_sent = 0;
  };
#endif
  if (!gpu_server.Listen(gpu_socket, &error)) {
    std::fprintf(stderr, "🦝 %s\n", error.c_str());
    // The engine runs already: its threads post to objects about to go.
    host.Shutdown();
    return 1;
  }
  std::fprintf(stdout, "🦝 listening on unix:%s\n",
               options.socket.c_str());
  std::fflush(stdout);

  // One turn of the loop's work: platform tasks, vsync, and what goes to
  // the client. The loop below takes one between waits; on Windows a
  // plugin's modal dialog takes them while its own message loop holds
  // ours (MessagePump).
  auto Turn = [&]() {
#if RACCOON_HAS_METAL
    if (ports_asked.exchange(false)) host.ShareGpuBuffersByPort(true);
#endif
    host.platform().RunDueTasks();
    host.ServiceVsync();
    host.ServiceCamera();
    SendLogs();
    // Nothing the client is sent blocks the loop, the app's platform
    // thread: messages queue while its socket is full (#144), and frames
    // wait in the renderer until the queue is empty, the newest replacing
    // the rest. A client paused in a debugger keeps its place; one that
    // leaves too much unread is let go by the server.
    // The GPU socket's too: a frame must not reach the client before the
    // fence it waits on (#146).
    frames_held = server.backlog() > 0 || gpu_server.backlog() > 0;
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
        if (!frames_held && host.frame().TakeGpu(&gpu)) {
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
      if (!frames_held && host.frame().TakeShared(&shared)) {
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
      if (!frames_held && host.frame().CopyLatest(&copy, last_sent)) {
        raccoon::v1::RunnerMessage message;
        raccoon::v1::Frame* frame = message.mutable_frame();
        frame->set_sequence(copy.sequence);
        frame->set_width(static_cast<uint32_t>(copy.width));
        frame->set_height(static_cast<uint32_t>(copy.height));
        frame->set_row_bytes(static_cast<uint32_t>(copy.row_bytes));
        frame->set_format(kPixelFormat);
        frame->set_pixels(std::move(copy.pixels));
        frame->set_timestamp_micros(host.NowMicros());
        server.Send(message);
        last_sent = copy.sequence;
      }
      // Resize the shared buffers only after the pending frame went out:
      // replacing the pool releases it, and that frame would be lost.
      // Shared buffers, sized for the current frame; replaced on resize.
      const size_t need = host.frame().LatestSizeBytes();
      if (client_shared && !client_gpu && need > 0 && !frames_held &&
          (!pool || pool->size() != need)) {
        host.frame().SetSharedPool(nullptr);
        auto fresh = std::make_unique<raccoon::SharedBufferPool>();
        std::string pool_error;
        if (fresh->Allocate(2, need, &pool_error)) {
          raccoon::v1::RunnerMessage message;
          message.mutable_shared_buffers()->set_count(2);
          message.mutable_shared_buffers()->set_size(need);
          message.mutable_shared_buffers()->set_generation(shared_generation + 1);
          if (server.SendWithFds(message, fresh->fds())) {
            ++shared_generation;
            pool = std::move(fresh);
            host.frame().SetSharedPool(pool.get());
          }
        } else {
          std::fprintf(stderr, "🦝 %s; frames stay inline\n",
                       pool_error.c_str());
          client_shared = false;
        }
      }
    }
    if (const int gone = GonePid(); gone != 0) {
      std::fprintf(stderr, "🦝 parent %d is gone; stopping\n", gone);
      stop = true;
    }
  };
#if RACCOON_HAS_PLUGINS && defined(_WIN32)
  if (plugins) plugins->SetModalTurn([&] {
    Turn();
    loop.RunOnce(0);
  });
#endif
  while (!stop && g_stop == 0) {
    Turn();
    // Frames held for the queue go once it drains: the socket's readiness
    // wakes the loop.
    loop.RunOnce(NextWait(host, ExpireReplies(1000)));
  }

  if (server.has_client()) {
    raccoon::v1::RunnerMessage exited;
    exited.mutable_exited()->set_code(0);
    server.Send(exited);
    server.Drain(2000);
  }
  host.Shutdown();
  capture.Stop();
  std::fprintf(stderr, "🦝 stopped\n");
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
#if defined(_WIN32)
  // Windows wakes waits on a 15.6 ms tick by default, so a loop paced at
  // 60 Hz would sleep two ticks a frame and draw at 32 fps. A millisecond,
  // for this process alone, while it runs.
  timeBeginPeriod(1);
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
