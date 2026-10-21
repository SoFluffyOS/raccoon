// raccoon_runner, M0: run an app bundle through the software renderer and
// write a frame. The embedder API is loaded at run time from --engine-dir.

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "engine_loader.h"
#include "flutter_embedder.h"
#include "platform_task_runner.h"
#include "software_frame.h"

namespace {

struct Options {
  std::string engine_dir;
  std::string assets;
  std::string icu;
  std::string out = "frame.ppm";
  size_t width = 800;
  size_t height = 600;
  double pixel_ratio = 1.0;
  size_t frames = 3;
  int timeout_ms = 10000;
  bool bgra = true;
};

void Usage() {
  std::fprintf(stderr,
               "usage: raccoon_runner --engine-dir DIR --assets DIR --icu FILE"
               " [--out frame.ppm] [--width N] [--height N] [--dpr X]"
               " [--frames N] [--timeout-ms N] [--rgba]\n");
}

bool ParseOptions(int argc, char** argv, Options* options) {
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    auto value = [&]() -> const char* {
      if (i + 1 >= argc) return nullptr;
      return argv[++i];
    };
    if (arg == "--rgba") {
      options->bgra = false;
      continue;
    }
    const char* v = value();
    if (v == nullptr) return false;
    if (arg == "--engine-dir") options->engine_dir = v;
    else if (arg == "--assets") options->assets = v;
    else if (arg == "--icu") options->icu = v;
    else if (arg == "--out") options->out = v;
    else if (arg == "--width") options->width = std::strtoul(v, nullptr, 10);
    else if (arg == "--height") options->height = std::strtoul(v, nullptr, 10);
    else if (arg == "--dpr") options->pixel_ratio = std::strtod(v, nullptr);
    else if (arg == "--frames") options->frames = std::strtoul(v, nullptr, 10);
    else if (arg == "--timeout-ms") options->timeout_ms = std::atoi(v);
    else return false;
  }
  return !options->engine_dir.empty() && !options->assets.empty() &&
         !options->icu.empty();
}

struct RunnerState {
  raccoon::SoftwareFrame frame;
  std::chrono::steady_clock::time_point started;
  std::chrono::steady_clock::time_point first_frame;
  bool saw_first_frame = false;
};

bool OnPresent(void* user_data, const void* allocation, size_t row_bytes,
               size_t height) {
  auto* state = static_cast<RunnerState*>(user_data);
  if (!state->saw_first_frame) {
    state->first_frame = std::chrono::steady_clock::now();
    state->saw_first_frame = true;
  }
  state->frame.Present(allocation, row_bytes, height);
  return true;
}

void OnLog(const char* tag, const char* message, void* /*user_data*/) {
  std::fprintf(stderr, "[engine%s%s] %s\n", tag && *tag ? ":" : "",
               tag ? tag : "", message);
}

long MillisSince(std::chrono::steady_clock::time_point since) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now() - since)
      .count();
}

}  // namespace

int main(int argc, char** argv) {
  Options options;
  if (!ParseOptions(argc, argv, &options)) {
    Usage();
    return 2;
  }

  raccoon::EngineLoader loader;
  std::string error;
  if (!loader.Load(options.engine_dir, &error)) {
    std::fprintf(stderr, "raccoon_runner: %s\n", error.c_str());
    return 1;
  }
  const FlutterEngineProcTable& procs = loader.procs();

  RunnerState state;

  FlutterRendererConfig renderer{};
  renderer.type = kSoftware;
  renderer.software.struct_size = sizeof(FlutterSoftwareRendererConfig);
  renderer.software.surface_present_callback = OnPresent;

  const char* command_line[] = {"raccoon_runner", "--enable-impeller=false"};

  FlutterProjectArgs args{};
  args.struct_size = sizeof(FlutterProjectArgs);
  args.assets_path = options.assets.c_str();
  args.icu_data_path = options.icu.c_str();
  args.command_line_argc = 2;
  args.command_line_argv = command_line;
  args.log_message_callback = OnLog;
  args.log_tag = "raccoon";

  raccoon::PlatformTaskRunner platform(procs);
  FlutterCustomTaskRunners runners{};
  runners.struct_size = sizeof(FlutterCustomTaskRunners);
  runners.platform_task_runner = &platform.description();
  args.custom_task_runners = &runners;

  state.started = std::chrono::steady_clock::now();
  FLUTTER_API_SYMBOL(FlutterEngine) engine = nullptr;
  FlutterEngineResult result =
      procs.Run(FLUTTER_ENGINE_VERSION, &renderer, &args, &state, &engine);
  if (result != kSuccess) {
    std::fprintf(stderr, "raccoon_runner: FlutterEngineRun failed (%d)\n",
                 static_cast<int>(result));
    return 1;
  }
  platform.SetEngine(engine);
  std::fprintf(stderr, "raccoon_runner: engine running after %ld ms\n",
               MillisSince(state.started));

  FlutterWindowMetricsEvent metrics{};
  metrics.struct_size = sizeof(FlutterWindowMetricsEvent);
  metrics.width = options.width;
  metrics.height = options.height;
  metrics.pixel_ratio = options.pixel_ratio;
  procs.SendWindowMetricsEvent(engine, &metrics);

  platform.PumpUntil(
      [&] { return state.frame.FrameCount() >= options.frames; },
      std::chrono::milliseconds(options.timeout_ms));
  const size_t presented = state.frame.FrameCount();
  if (state.saw_first_frame) {
    std::fprintf(stderr, "raccoon_runner: first frame after %ld ms\n",
                 std::chrono::duration_cast<std::chrono::milliseconds>(
                     state.first_frame - state.started)
                     .count());
  }
  std::fprintf(stderr, "raccoon_runner: %zu frames presented, %zux%zu\n",
               presented, state.frame.width(), state.frame.height());

  int exit_code = 0;
  if (!state.frame.WritePpm(options.out, options.bgra)) {
    std::fprintf(stderr, "raccoon_runner: no frame written to %s\n",
                 options.out.c_str());
    exit_code = 1;
  } else {
    std::fprintf(stderr, "raccoon_runner: wrote %s\n", options.out.c_str());
  }

  platform.RunDueTasks();
  const auto shutdown_started = std::chrono::steady_clock::now();
  procs.Shutdown(engine);
  std::fprintf(stderr, "raccoon_runner: shutdown took %ld ms\n",
               MillisSince(shutdown_started));
  return exit_code;
}
