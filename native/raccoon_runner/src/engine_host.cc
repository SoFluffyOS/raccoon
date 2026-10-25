#include "engine_host.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <nlohmann/json.hpp>
#if defined(_WIN32)
#include <io.h>
#else
#include <unistd.h>
#endif

#include "host_settings.h"
#include "key_codes.h"
#include "secure_storage_options.h"

namespace raccoon {

namespace {

constexpr char kVmServiceMarker[] = "listening on ";
// The one display the runner reports; window metrics name it.
constexpr FlutterEngineDisplayId kDisplayId = 0;

}  // namespace

bool EngineHost::Start(const EngineOptions& options, LogCallback on_log,
                       std::function<void()> on_wake, std::string* error) {
  if (!loader_.Load(options.engine_dir, error)) return false;
  const FlutterEngineProcTable& procs = loader_.procs();

  on_log_ = std::move(on_log);
  on_wake_ = std::move(on_wake);
  assets_ = options.assets;
  {
    std::string source = options.camera_source;
    if (const char* env = std::getenv("RACCOON_CAMERA_SOURCE"); source.empty() && env != nullptr) {
      source = env;
    }
    std::string why;
    if (!source.empty() && !camera_.SetSource(source, &why)) {
      std::fprintf(stderr, "🦝 camera source %s: %s; the camera shows its test pattern\n",
                   source.c_str(), why.c_str());
    }
  }
  camera_.SetClock([this] { return NowMicros(); });
  camera_.SetSend([this](const std::string& channel, std::vector<uint8_t> message) {
    SendPlatformMessage(channel, message.data(), message.size());
  });
  if (!options.data_dir.empty()) {
    user_defaults_.SetStorePath(options.data_dir + "/shared_preferences.bin");
#if !defined(_WIN32)
    // On Linux, path_provider and shared_preferences are Dart only: they
    // name their directories after the executable under the XDG base
    // directories, so every hosted app would share one. Pointed into the
    // app's own directory, they stay apart. Set before the engine runs, so
    // the app sees them.
    // Mesa keeps its shader cache under the cache home too; that one stays
    // the user's, shared by every app, so first frames do not pay for
    // shader compiles app by app.
    if (std::getenv("MESA_SHADER_CACHE_DIR") == nullptr) {
      std::string cache_home;
      if (const char* xdg = std::getenv("XDG_CACHE_HOME"); xdg != nullptr && *xdg != '\0') {
        cache_home = xdg;
      } else if (const char* home = std::getenv("HOME"); home != nullptr) {
        cache_home = std::string(home) + "/.cache";
      }
      if (!cache_home.empty()) {
        setenv("MESA_SHADER_CACHE_DIR", (cache_home + "/mesa_shader_cache").c_str(), 1);
      }
    }
    setenv("XDG_DATA_HOME", (options.data_dir + "/xdg/data").c_str(), 1);
    setenv("XDG_CACHE_HOME", (options.data_dir + "/xdg/cache").c_str(), 1);
#endif
    // Windows' path_provider asks the shell for its known folders, which no
    // variable moves, so apps there still share theirs.
  }
  icu_ = options.icu;

  platform_ = std::make_unique<PlatformTaskRunner>(procs);
  platform_->SetWakeCallback(on_wake_);
  frame_.SetPresentedCallback(on_wake_);

  FlutterRendererConfig renderer{};
  if (!ConfigureRenderer(options.renderer, &renderer, error)) return false;
  GiveCameraTextures();
  if (gpu_) {
    gpu_->SetGpuFrameCallback([this](uint32_t generation, int index, size_t width,
                                     size_t height, int fence_fd) {
      frame_.PresentGpu(generation, index, width, height, fence_fd);
    });
    frame_.SetGpuReleaseCallback([this](uint32_t generation, int index) {
      gpu_->Release(generation, index, -1);
    });
  }

  command_line_ = {"raccoon_runner", "--enable-impeller=false"};
  for (const std::string& arg : options.extra_args) command_line_.push_back(arg);
  argv_.clear();
  for (const std::string& arg : command_line_) argv_.push_back(arg.c_str());

  runners_.struct_size = sizeof(FlutterCustomTaskRunners);
  runners_.platform_task_runner = &platform_->description();

  FlutterProjectArgs args{};
  args.struct_size = sizeof(FlutterProjectArgs);
  args.assets_path = assets_.c_str();
  args.icu_data_path = icu_.c_str();
  args.command_line_argc = static_cast<int>(argv_.size());
  args.command_line_argv = argv_.data();
  args.log_message_callback = OnLog;
  args.log_tag = "raccoon";
  args.custom_task_runners = &runners_;
  args.platform_message_callback = OnPlatformMessage;
  args.vsync_callback = OnVsync;

  started_ = std::chrono::steady_clock::now();
  const FlutterEngineResult result =
      procs.Run(FLUTTER_ENGINE_VERSION, &renderer, &args, this, &engine_);
  if (result != kSuccess) {
    *error = "FlutterEngineRun failed with " + std::to_string(result);
    return false;
  }
  platform_->SetEngine(engine_);
  text_input_.SetSender([this](const std::string& channel, const std::string& json) {
    SendPlatformMessage(channel, reinterpret_cast<const uint8_t*>(json.data()),
                        json.size());
  });
  // Report one display, as desktop embedders do once the engine runs; apps
  // that read PlatformDispatcher.displays (Wonderous does) find it. Calling
  // this before the engine runs crashes inside the engine.
  FlutterEngineDisplay display{};
  display.struct_size = sizeof(FlutterEngineDisplay);
  display.display_id = kDisplayId;
  display.single_display = true;
  display.refresh_rate = 60.0;
  display.width = options.width;
  display.height = options.height;
  display.device_pixel_ratio = options.pixel_ratio;
  procs.NotifyDisplayUpdate(engine_, kFlutterEngineDisplaysUpdateTypeStartup,
                            &display, 1);
  Resize(options.width, options.height, options.pixel_ratio);
  SendHostSettings();
  // The app is shown, as far as the runner knows: desktop embeddings say
  // so once the engine runs, and without it the app's lifecycle stays null.
  static constexpr char kResumed[] = "AppLifecycleState.resumed";
  SendPlatformMessage("flutter/lifecycle", reinterpret_cast<const uint8_t*>(kResumed),
                      sizeof(kResumed) - 1);
  if (on_log_) on_log_("raccoon_runner", "🦝 renderer " + renderer_);
  return true;
}

void EngineHost::SendHostSettings() {
  // What a desktop embedding tells its app at start: without it the app
  // sees no locales and a light, 12-hour host.
  const HostSettings settings = ReadHostSettings();
  std::vector<FlutterLocale> locales;
  for (const HostLocale& locale : settings.locales) {
    FlutterLocale entry{};
    entry.struct_size = sizeof(FlutterLocale);
    entry.language_code = locale.language.c_str();
    entry.country_code = locale.country.empty() ? nullptr : locale.country.c_str();
    entry.script_code = locale.script.empty() ? nullptr : locale.script.c_str();
    locales.push_back(entry);
  }
  std::vector<const FlutterLocale*> pointers;
  for (const FlutterLocale& locale : locales) pointers.push_back(&locale);
  if (!pointers.empty()) {
    loader_.procs().UpdateLocales(engine_, pointers.data(), pointers.size());
  }
  const std::string json = nlohmann::json{
      {"textScaleFactor", 1.0},
      {"alwaysUse24HourFormat", settings.always_24_hour},
      {"platformBrightness", settings.dark ? "dark" : "light"},
  }.dump();
  SendPlatformMessage("flutter/settings", reinterpret_cast<const uint8_t*>(json.data()),
                      json.size());
}

void EngineHost::Resize(size_t width, size_t height, double pixel_ratio) {
  // A frame too large for the GPU (Metal aborts past 16,384 pixels a side,
  // GL drivers stop sooner) is scaled down to fit, its pixel ratio with it:
  // the app keeps its logical size at a lower resolution, and the host shows
  // the frame stretched as it does any (#117). 8,192 is wider than any
  // display.
  constexpr size_t kMaxSide = 8192;
  const size_t longest = std::max(width, height);
  input_scale_ = 1.0;
  if (longest > kMaxSide) {
    const double scale = static_cast<double>(kMaxSide) / static_cast<double>(longest);
    width = std::max<size_t>(1, static_cast<size_t>(std::lround(width * scale)));
    height = std::max<size_t>(1, static_cast<size_t>(std::lround(height * scale)));
    pixel_ratio *= scale;
    input_scale_ = scale;
  }
  FlutterWindowMetricsEvent metrics{};
  metrics.struct_size = sizeof(FlutterWindowMetricsEvent);
  metrics.width = width;
  metrics.height = height;
  metrics.pixel_ratio = pixel_ratio;
  metrics.display_id = kDisplayId;
  metrics_ = metrics;
  loader_.procs().SendWindowMetricsEvent(engine_, &metrics);
  windows_.SetViewSize(width, height, pixel_ratio);
}

void EngineHost::Redraw() {
  // The framework draws a frame for metrics it is sent, the same or not.
  if (engine_ == nullptr || metrics_.width == 0) return;
  loader_.procs().SendWindowMetricsEvent(engine_, &metrics_);
}

bool EngineHost::ConfigureRenderer(const std::string& wanted,
                                   FlutterRendererConfig* renderer,
                                   std::string* error) {
  // "auto" takes the GPU renderer this host builds when it starts, else
  // software; "gl", "metal" and "vulkan" insist on theirs; "software" never
  // tries.
  const bool insists = wanted == "gl" || wanted == "metal" || wanted == "vulkan";
  std::string gpu_error;
  const char* kind = "GPU";
#if RACCOON_HAS_VULKAN
  if (wanted == "auto" || wanted == "vulkan") {
    kind = "Vulkan";
    auto vulkan = std::make_unique<VulkanRenderer>();
    if (vulkan->Init(&gpu_error)) {
      vulkan_ = vulkan.get();
      gpu_ = std::move(vulkan);
      renderer->type = kVulkan;
      auto& config = renderer->vulkan;
      config.struct_size = sizeof(FlutterVulkanRendererConfig);
      config.version = vulkan_->api_version();
      config.instance = vulkan_->instance();
      config.physical_device = vulkan_->physical_device();
      config.device = vulkan_->device();
      config.queue_family_index = vulkan_->queue_family();
      config.queue = vulkan_->queue();
      config.get_instance_proc_address_callback = VulkanProc;
      config.get_next_image_callback = VulkanNextImage;
      config.present_image_callback = VulkanPresent;
      renderer_ = "vulkan (" + vulkan_->description() + ")";
      return true;
    }
  }
#endif
#if RACCOON_HAS_GL
  if (wanted != "software" && wanted != "metal") {
    kind = "GL";
    auto gl = std::make_unique<GlRenderer>();
    if (gl->Init(&gpu_error)) {
      gl_ = gl.get();
      gpu_ = std::move(gl);
      renderer->type = kOpenGL;
      auto& config = renderer->open_gl;
      config.struct_size = sizeof(FlutterOpenGLRendererConfig);
      config.make_current = GlMakeCurrent;
      config.clear_current = GlClearCurrent;
      config.make_resource_current = GlMakeResourceCurrent;
      config.fbo_with_frame_info_callback = GlFbo;
      config.present_with_info = GlPresent;
      config.gl_external_texture_frame_callback = GlExternalTexture;
      config.gl_proc_resolver = GlProc;
      // Ask for the framebuffer every frame: with a pool it is a different
      // buffer each time.
      config.fbo_reset_after_present = true;
      renderer_ = "gl (" + gl_->description() + ")";
      return true;
    }
  }
#endif
#if RACCOON_HAS_METAL
  if (wanted != "software" && wanted != "gl") {
    kind = "Metal";
    auto metal = std::make_unique<MetalRenderer>();
    if (metal->Init(&gpu_error)) {
      metal_ = metal.get();
      gpu_ = std::move(metal);
      renderer->type = kMetal;
      auto& config = renderer->metal;
      config.struct_size = sizeof(FlutterMetalRendererConfig);
      config.device = metal_->device();
      config.present_command_queue = metal_->command_queue();
      config.get_next_drawable_callback = MetalNextDrawable;
      config.present_drawable_callback = MetalPresent;
      config.external_texture_frame_callback = MetalExternalTexture;
      renderer_ = "metal (" + metal_->description() + ")";
      return true;
    }
  }
#endif
  if (insists) {
    *error = gpu_error.empty()
                 ? "this runner was built without the " + wanted + " renderer"
                 : wanted + " renderer: " + gpu_error;
    return false;
  }
  if (!gpu_error.empty()) {
    renderer_ = "software (no " + std::string(kind) + ": " + gpu_error + ")";
  }
  renderer->type = kSoftware;
  renderer->software.struct_size = sizeof(FlutterSoftwareRendererConfig);
  renderer->software.surface_present_callback = OnPresent;
  return true;
}

#if RACCOON_HAS_GL
bool EngineHost::GlMakeCurrent(void* user_data) {
  return static_cast<EngineHost*>(user_data)->gl_->MakeCurrent();
}

bool EngineHost::GlClearCurrent(void* user_data) {
  return static_cast<EngineHost*>(user_data)->gl_->ClearCurrent();
}

bool EngineHost::GlMakeResourceCurrent(void* user_data) {
  return static_cast<EngineHost*>(user_data)->gl_->MakeResourceCurrent();
}

uint32_t EngineHost::GlFbo(void* user_data, const FlutterFrameInfo* info) {
  return static_cast<EngineHost*>(user_data)->gl_->Fbo(info->size.width,
                                                       info->size.height);
}

bool EngineHost::GlPresent(void* user_data, const FlutterPresentInfo* /*info*/) {
  auto* host = static_cast<EngineHost*>(user_data);
  return host->gl_->Present(
      [host](const void* pixels, size_t row_bytes, size_t height) {
        OnPresent(host, pixels, row_bytes, height);
      });
}

void* EngineHost::GlProc(void* user_data, const char* name) {
  return static_cast<EngineHost*>(user_data)->gl_->ProcAddress(name);
}
#endif

#if RACCOON_HAS_METAL
FlutterMetalTexture EngineHost::MetalNextDrawable(void* user_data,
                                                  const FlutterFrameInfo* info) {
  // A null texture tells the engine there is none for this frame.
  FlutterMetalTexture texture{};
  texture.struct_size = sizeof(FlutterMetalTexture);
  static_cast<EngineHost*>(user_data)->metal_->NextDrawable(
      info->size.width, info->size.height, &texture.texture_id, &texture.texture);
  return texture;
}

bool EngineHost::MetalPresent(void* user_data, const FlutterMetalTexture* texture) {
  auto* host = static_cast<EngineHost*>(user_data);
  return host->metal_->Present(
      texture->texture_id,
      [host](const void* pixels, size_t row_bytes, size_t height) {
        OnPresent(host, pixels, row_bytes, height);
      });
}
#endif

#if RACCOON_HAS_VULKAN
void* EngineHost::VulkanProc(void* user_data, FlutterVulkanInstanceHandle instance,
                             const char* name) {
  return static_cast<EngineHost*>(user_data)->vulkan_->ProcAddress(
      static_cast<VkInstance>(instance), name);
}

FlutterVulkanImage EngineHost::VulkanNextImage(void* user_data, const FlutterFrameInfo* info) {
  // A null image tells the engine there is none for this frame.
  FlutterVulkanImage image{};
  image.struct_size = sizeof(FlutterVulkanImage);
  image.image = reinterpret_cast<FlutterVulkanImageHandle>(
      static_cast<EngineHost*>(user_data)->vulkan_->NextImage(info->size.width,
                                                              info->size.height));
  image.format = VulkanRenderer::kFormat;
  return image;
}

bool EngineHost::VulkanPresent(void* user_data, const FlutterVulkanImage* image) {
  auto* host = static_cast<EngineHost*>(user_data);
  return host->vulkan_->Present(
      reinterpret_cast<VkImage>(image->image),
      [host](const void* pixels, size_t row_bytes, size_t height) {
        OnPresent(host, pixels, row_bytes, height);
      });
}
#endif

bool EngineHost::EnableGpuBuffers(size_t count, std::string* error) {
  if (gpu_) return gpu_->EnablePool(count, error);
  *error = "the software renderer has no GPU buffers";
  return false;
}

#if RACCOON_HAS_METAL
bool EngineHost::ShareGpuBuffersByPort(bool by_port) {
  if (metal_ == nullptr) return false;
  if (metal_->ShareByPort(by_port) && engine_ != nullptr) {
    loader_.procs().ScheduleFrame(engine_);
  }
  return true;
}

bool EngineHost::GpuBufferPorts(uint32_t generation, std::vector<uint32_t>* ports) const {
  return metal_ != nullptr && metal_->SurfacePorts(generation, ports);
}
#endif

void EngineHost::DisableGpuBuffers() {
  if (gpu_) gpu_->DisablePool();
}

bool EngineHost::GpuBufferSetNow(GpuBufferSet* out) const {
  return gpu_ && gpu_->pool_set(out);
}

void EngineHost::ReleaseGpuBuffer(uint32_t generation, int index, int fence_fd) {
  if (gpu_) {
    gpu_->Release(generation, index, fence_fd);
    bool owed = false;
    {
      std::lock_guard<std::mutex> lock(vsync_mutex_);
      std::swap(owed, gpu_frame_owed_);
    }
    // The renderer knows where the frame went: on GL the buffer is taken
    // at the frame before, so the vsync's guess can miss it.
    if (gpu_->TakeMissedFrame()) owed = true;
    // An app gone idle since would leave the client on an older frame.
    if (owed && engine_ != nullptr) loader_.procs().ScheduleFrame(engine_);
    return;
  }
  if (fence_fd >= 0) close(fence_fd);
}

namespace {
constexpr uint64_t kFrameNanos = 16666667;  // 60 Hz
// How long a frame waits for a ring buffer before going by readback.
constexpr uint64_t kRingHoldNanos = 100000000;
}  // namespace

void EngineHost::OnVsync(void* user_data, intptr_t baton) {
  auto* host = static_cast<EngineHost*>(user_data);
  {
    std::lock_guard<std::mutex> lock(host->vsync_mutex_);
    host->vsync_pending_ = true;
    host->vsync_baton_ = baton;
    host->vsync_asked_nanos_ = host->loader_.procs().GetCurrentTime();
  }
  if (host->on_wake_) host->on_wake_();
}

void EngineHost::ServiceVsync() {
  intptr_t baton = 0;
  uint64_t start = 0;
  {
    std::lock_guard<std::mutex> lock(vsync_mutex_);
    if (!vsync_pending_ || engine_ == nullptr) return;
    const uint64_t now = loader_.procs().GetCurrentTime();
    if (now < next_frame_nanos_) return;
    bool free = true;
    if (gpu_) free = gpu_->HasFreeBuffer();
    if (!free && now - vsync_asked_nanos_ < kRingHoldNanos) return;
    if (!free) gpu_frame_owed_ = true;
    vsync_pending_ = false;
    baton = vsync_baton_;
    start = now;
    // Frames keep to a 60 Hz grid: the next is due one interval after this
    // one was, not after the loop woke for it, so a late wake-up costs one
    // frame and is not carried into every frame after. After a pause longer
    // than a frame (an idle app) the grid starts again from now.
    const uint64_t due = now - next_frame_nanos_ > kFrameNanos ? now : next_frame_nanos_;
    next_frame_nanos_ = due + kFrameNanos;
  }
  loader_.procs().OnVsync(engine_, baton, start, start + kFrameNanos);
}

int EngineHost::MillisUntilVsync() const {
  std::lock_guard<std::mutex> lock(vsync_mutex_);
  if (!vsync_pending_ || engine_ == nullptr) return -1;
  const uint64_t now = loader_.procs().GetCurrentTime();
  uint64_t due = next_frame_nanos_;
  bool free = true;
  if (gpu_) free = gpu_->HasFreeBuffer();
  // A release wakes the loop sooner; this is only the cap.
  if (!free) due = std::max(due, vsync_asked_nanos_ + kRingHoldNanos);
  if (due <= now) return 0;
  return static_cast<int>((due - now + 999999) / 1000000);
}

void EngineHost::ServiceCamera() {
  if (engine_ == nullptr) return;
  camera_.Service(NowMicros());
}

int EngineHost::MillisUntilCamera() const {
  if (engine_ == nullptr) return -1;
  return camera_.MillisUntilDue(NowMicros());
}

void EngineHost::RedrawIfMissed() {
  if (!gpu_ || engine_ == nullptr || !gpu_->HasFreeBuffer()) return;
  if (gpu_->TakeMissedFrame()) loader_.procs().ScheduleFrame(engine_);
}

void EngineHost::ReleaseAllGpuBuffers() {
  if (gpu_) gpu_->ReleaseAll();
}

void EngineHost::SendPointer(const FlutterPointerEvent& event) {
  if (input_scale_ == 1.0) {
    loader_.procs().SendPointerEvent(engine_, &event, 1);
    return;
  }
  // A frame scaled down to fit (#117): the host points in the size it asked
  // for, so its positions and distances scale the same way (#130).
  FlutterPointerEvent scaled = event;
  scaled.x *= input_scale_;
  scaled.y *= input_scale_;
  scaled.scroll_delta_x *= input_scale_;
  scaled.scroll_delta_y *= input_scale_;
  scaled.pan_x *= input_scale_;
  scaled.pan_y *= input_scale_;
  loader_.procs().SendPointerEvent(engine_, &scaled, 1);
}

namespace {

struct ReplyContext {
  std::function<void(const uint8_t* data, size_t size)> on_reply;
};

void OnReply(const uint8_t* data, size_t size, void* user_data) {
  auto* context = static_cast<ReplyContext*>(user_data);
  context->on_reply(data, size);
  delete context;
}

#if !defined(__APPLE__)
// The first code point of a UTF-8 string, 0 for none.
uint32_t FirstCodePoint(const std::string& utf8) {
  if (utf8.empty()) return 0;
  const unsigned char c = utf8[0];
  size_t length = 1;
  uint32_t code = c;
  if ((c & 0xE0) == 0xC0) {
    length = 2;
    code = c & 0x1F;
  } else if ((c & 0xF0) == 0xE0) {
    length = 3;
    code = c & 0x0F;
  } else if ((c & 0xF8) == 0xF0) {
    length = 4;
    code = c & 0x07;
  }
  if (utf8.size() < length) return 0;
  for (size_t k = 1; k < length; ++k) {
    code = (code << 6) | (static_cast<unsigned char>(utf8[k]) & 0x3F);
  }
  return code;
}
#endif

}  // namespace

namespace {

// Bits of EngineHost::modifiers_: left, then right.
constexpr uint64_t kControlLeft = 0x200000100;
constexpr uint8_t kControl = 0x03;
constexpr uint8_t kShift = 0x0C;
constexpr uint8_t kAlt = 0x30;
constexpr uint8_t kMeta = 0xC0;

}  // namespace

// Each side on its own: with both Shifts down, letting one go leaves Shift
// held.
void EngineHost::TrackModifiers(const FlutterKeyEvent& event) {
  if (event.logical < kControlLeft || event.logical > kControlLeft + 7) return;
  const auto bit = static_cast<uint8_t>(1u << (event.logical - kControlLeft));
  if (event.type == kFlutterKeyEventTypeUp) {
    modifiers_ &= static_cast<uint8_t>(~bit);
  } else {
    modifiers_ |= bit;
  }
}

std::string EngineHost::RawKeyMessage(const FlutterKeyEvent& event,
                                      const std::string& character) const {
  // The framework reads this message by host keymap; only the logical key
  // and the character matter to it, the rest feeds the deprecated
  // RawKeyboard, which keeps pressed keys by the physical key it reads from
  // the platform's code.
  const bool shift = (modifiers_ & kShift) != 0;
  const bool control = (modifiers_ & kControl) != 0;
  const bool alt = (modifiers_ & kAlt) != 0;
  const bool meta = (modifiers_ & kMeta) != 0;
  nlohmann::json message;
  message["type"] = event.type == kFlutterKeyEventTypeUp ? "keyup" : "keydown";
  message["specifiedLogicalKey"] = event.logical;
#if defined(__APPLE__)
  message["keymap"] = "macos";
  message["keyCode"] = PlatformKeyCode(event.physical);
  message["characters"] = character;
  message["charactersIgnoringModifiers"] = character;
  message["modifiers"] = (shift ? 0x20000 : 0) | (control ? 0x40000 : 0) |
                         (alt ? 0x80000 : 0) | (meta ? 0x100000 : 0);
#elif defined(_WIN32)
  message["keymap"] = "windows";
  message["keyCode"] = 0;
  message["scanCode"] = PlatformKeyCode(event.physical);
  message["characterCodePoint"] = FirstCodePoint(character);
  // Either side, then left and right, as RawKeyEventDataWindows has them;
  // Meta has sides only.
  const auto bits = [this](uint8_t mask, int any, int left) {
    const int pressed = modifiers_ & mask;
    if (pressed == 0) return 0;
    const int low = pressed & (mask & -mask);
    return (any >= 0 ? 1 << any : 0) | (low != 0 ? 1 << left : 0) |
           (pressed != low ? 1 << (left + 1) : 0);
  };
  message["modifiers"] = bits(kShift, 0, 1) | bits(kControl, 3, 4) | bits(kAlt, 6, 7) |
                         bits(kMeta, -1, 9);
#else
  message["keymap"] = "linux";
  message["toolkit"] = "gtk";
  message["keyCode"] = 0;
  message["scanCode"] = PlatformKeyCode(event.physical);
  message["unicodeScalarValues"] = FirstCodePoint(character);
  message["modifiers"] = (shift ? 1 << 0 : 0) | (control ? 1 << 2 : 0) |
                         (alt ? 1 << 3 : 0) | (meta ? 1 << 26 : 0);
#endif
  return message.dump();
}

void EngineHost::SendKey(const FlutterKeyEvent& event) {
  TrackModifiers(event);
  loader_.procs().SendKeyEvent(
      engine_, &event, [](bool /*handled*/, void* /*user_data*/) {}, nullptr);
  if (event.synthesized) return;
  // The framework holds key data until the legacy flutter/keyevent message
  // for the same key arrives, and answers that one with whether it handled
  // the key. A key down it leaves alone edits the text field, if any.
  const std::string character =
      event.character == nullptr ? std::string() : event.character;
  const bool down = event.type != kFlutterKeyEventTypeUp;
  const std::string raw = RawKeyMessage(event, character);
  const uint64_t logical = event.logical;
  SendPlatformMessage(
      "flutter/keyevent", reinterpret_cast<const uint8_t*>(raw.data()),
      raw.size(),
      // The modifiers as the key was pressed, not as the reply finds them.
      [this, down, logical, character, shift = (modifiers_ & kShift) != 0,
       control = (modifiers_ & kControl) != 0, alt = (modifiers_ & kAlt) != 0,
       meta = (modifiers_ & kMeta) != 0](const uint8_t* data, size_t size) {
        if (!down) return;
        const auto reply = nlohmann::json::parse(data, data + size, nullptr, false);
        const bool handled = reply.is_object() && reply.contains("handled") &&
                             reply["handled"].is_boolean() &&
                             reply["handled"].get<bool>();
        if (handled) return;
        text_input_.HandleKey(logical, character, shift, control, alt, meta);
      });
}

void EngineHost::SendPlatformMessage(
    const std::string& channel, const uint8_t* data, size_t size,
    std::function<void(const uint8_t* data, size_t size)> on_reply) {
  if (engine_ == nullptr) return;
  const auto& procs = loader_.procs();
  FlutterPlatformMessageResponseHandle* handle = nullptr;
  if (on_reply) {
    auto* context = new ReplyContext{std::move(on_reply)};
    if (procs.PlatformMessageCreateResponseHandle(engine_, OnReply, context,
                                                  &handle) != kSuccess) {
      delete context;
      handle = nullptr;
    }
  }
  FlutterPlatformMessage message{};
  message.struct_size = sizeof(FlutterPlatformMessage);
  message.channel = channel.c_str();
  message.message = data;
  message.message_size = size;
  message.response_handle = handle;
  procs.SendPlatformMessage(engine_, &message);
  if (handle != nullptr) {
    procs.PlatformMessageReleaseResponseHandle(engine_, handle);
  }
}

void EngineHost::Respond(const FlutterPlatformMessageResponseHandle* handle,
                         const uint8_t* data, size_t size) {
  if (engine_ == nullptr || handle == nullptr) return;
  loader_.procs().SendPlatformMessageResponse(engine_, handle, data, size);
}

void EngineHost::RespondNoPlugin(const std::string& channel,
                                 const FlutterPlatformMessageResponseHandle* handle,
                                 const char* why) {
  if (handle == nullptr) return;
  Respond(handle, nullptr, 0);
  // The engine's own channels (flutter/keyboard, flutter/platform, ...) are
  // the embedder's to answer, and the framework takes a null reply there
  // as "this host does not do that": nothing failed, nothing to say.
  if (channel.rfind("flutter/", 0) == 0) return;
  if (!unanswered_.insert(std::string(why) + '\n' + channel).second) return;
  std::fprintf(stderr, "🦝 nothing answered %s (%s); the app sees no plugin\n",
               channel.c_str(), why);
}

void EngineHost::OnPlatformMessage(const FlutterPlatformMessage* message,
                                   void* user_data) {
  auto* host = static_cast<EngineHost*>(user_data);
  const std::string channel = message->channel == nullptr ? "" : message->channel;
  // The window and shared preferences channels are the runner's own: it is
  // the app's window host, and apps call them at startup, before a client may
  // be connected.
  std::vector<uint8_t> reply;
  if (host->windows_.Handle(channel, message->message, message->message_size,
                            &reply) ||
      host->user_defaults_.Handle(channel, message->message,
                                  message->message_size, &reply) ||
      host->text_input_.Handle(channel, message->message,
                               message->message_size, &reply) ||
      host->camera_.Handle(channel, message->message, message->message_size,
                           &reply)) {
    host->Respond(message->response_handle, reply.data(), reply.size());
    return;
  }
#if RACCOON_HAS_PLUGINS
  // A loaded plugin answers its own channels, before a client sees them.
  if (host->plugins_) {
    const uint8_t* data = message->message;
    size_t size = message->message_size;
#if defined(__APPLE__)
    std::vector<uint8_t> rewritten;
    if (RewriteSecureStorageCall(channel, data, size, &rewritten)) {
      data = rewritten.data();
      size = rewritten.size();
    }
#endif
    if (host->plugins_->HandleMessage(channel, data, size, message->response_handle)) {
      return;
    }
  }
#endif
  if (host->on_platform_message_) {
    host->on_platform_message_(channel, message->message, message->message_size,
                               message->response_handle);
    return;
  }
  host->RespondNoPlugin(channel, message->response_handle, "no handler");
}

bool EngineHost::LoadPlugins(const std::string& manifest, std::string* error) {
#if RACCOON_HAS_PLUGINS
  if (engine_ == nullptr) {
    *error = "the engine is not running";
    return false;
  }
  if (!plugins_) {
    PluginHost::Bridge bridge;
    bridge.send = [this](const std::string& channel, const uint8_t* data, size_t size,
                         std::function<void(const uint8_t*, size_t)> on_reply) {
      PluginCall([&] { SendPlatformMessage(channel, data, size, std::move(on_reply)); return true; });
    };
    bridge.respond = [this](const FlutterPlatformMessageResponseHandle* handle,
                            const uint8_t* data, size_t size) {
      PluginCall([&] { Respond(handle, data, size); return true; });
    };
    bridge.register_texture = [this](int64_t id) {
      return PluginCall(
          [&] { return loader_.procs().RegisterExternalTexture(engine_, id) == kSuccess; });
    };
    bridge.mark_texture_frame_available = [this](int64_t id) {
      return PluginCall([&] {
        return loader_.procs().MarkExternalTextureFrameAvailable(engine_, id) == kSuccess;
      });
    };
    bridge.unregister_texture = [this](int64_t id) {
      return PluginCall(
          [&] { return loader_.procs().UnregisterExternalTexture(engine_, id) == kSuccess; });
    };
#if RACCOON_HAS_METAL
    bridge.metal_device = metal_ != nullptr ? metal_->device() : nullptr;
#endif
    plugins_ = std::make_unique<PluginHost>(std::move(bridge));
  }
  return plugins_->LoadManifest(manifest, error);
#else
  (void)manifest;
  *error = "this runner was built without native plugins";
  return false;
#endif
}

#if RACCOON_HAS_PLUGINS
const std::vector<PluginStatus>& EngineHost::plugin_statuses() const {
  static const std::vector<PluginStatus> kNone;
  return plugins_ ? plugins_->statuses() : kNone;
}
#endif

size_t EngineHost::plugins_loaded() const {
#if RACCOON_HAS_PLUGINS
  return plugins_ ? plugins_->loaded() : 0;
#else
  return 0;
#endif
}

void EngineHost::GiveCameraTextures() {
  std::function<void(int64_t)> forget;
#if RACCOON_HAS_METAL
  if (metal_ != nullptr) forget = [this](int64_t id) { metal_->ForgetPixelTexture(id); };
#endif
#if RACCOON_HAS_GL
  if (gl_ != nullptr) forget = [this](int64_t id) { gl_->ForgetPixelTexture(id); };
#endif
  // The software and Vulkan renderers draw no external textures.
  if (!forget) return;
  CameraChannels::Textures textures;
  textures.add = [this](int64_t id) {
    return engine_ != nullptr && loader_.procs().RegisterExternalTexture(engine_, id) == kSuccess;
  };
  textures.frame = [this](int64_t id) {
    if (engine_ != nullptr) loader_.procs().MarkExternalTextureFrameAvailable(engine_, id);
  };
  textures.remove = [this, forget](int64_t id) {
    if (engine_ != nullptr) loader_.procs().UnregisterExternalTexture(engine_, id);
    forget(id);
  };
  camera_.SetTextures(std::move(textures));
}

#if RACCOON_HAS_METAL
bool EngineHost::MetalExternalTexture(void* user_data, int64_t texture_id, size_t width,
                                      size_t height, FlutterMetalExternalTexture* out) {
  auto* host = static_cast<EngineHost*>(user_data);
  if (const auto preview = host->camera_.PreviewOf(texture_id)) {
    return host->metal_->PixelTexture(texture_id, preview->width, preview->height,
                                      preview->number, preview->bgra.data(), out);
  }
#if RACCOON_HAS_PLUGINS
  return host->plugins_ && host->plugins_->PopulateTexture(texture_id, width, height, out);
#else
  return false;
#endif
}
#endif

#if RACCOON_HAS_GL
bool EngineHost::GlExternalTexture(void* user_data, int64_t texture_id, size_t width,
                                   size_t height, FlutterOpenGLTexture* out) {
  auto* host = static_cast<EngineHost*>(user_data);
  if (const auto preview = host->camera_.PreviewOf(texture_id)) {
    return host->gl_->PixelTexture(texture_id, preview->width, preview->height,
                                   preview->number, preview->bgra.data(), out);
  }
#if RACCOON_HAS_PLUGINS
  return host->plugins_ && host->plugins_->PopulateTexture(texture_id, width, height, out);
#else
  return false;
#endif
}
#endif

#if RACCOON_HAS_PLUGINS
template <typename Call>
bool EngineHost::PluginCall(Call call) {
  ++plugin_calls_;
  const bool made = !stopping_ && engine_ != nullptr && call();
  --plugin_calls_;
  return made;
}
#endif

void EngineHost::Shutdown() {
  if (engine_ == nullptr) return;
  platform_->RunDueTasks();
#if RACCOON_HAS_PLUGINS
  // From here a plugin's call does nothing; the ones under way finish first.
  stopping_ = true;
  while (plugin_calls_ > 0) std::this_thread::yield();
#endif
  loader_.procs().Shutdown(engine_);
  engine_ = nullptr;
  // A task still queued must not run on the engine now gone.
  platform_->SetEngine(nullptr);
  if (gpu_) gpu_->Shutdown();
}

std::string EngineHost::vm_service_uri() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return vm_service_uri_;
}

bool EngineHost::OnPresent(void* user_data, const void* allocation,
                           size_t row_bytes, size_t height) {
  static_cast<EngineHost*>(user_data)->frame_.Present(allocation, row_bytes,
                                                      height);
  return true;
}

void EngineHost::OnLog(const char* tag, const char* message, void* user_data) {
  auto* host = static_cast<EngineHost*>(user_data);
  const std::string text = message == nullptr ? "" : message;
  const size_t marker = text.find(kVmServiceMarker);
  if (marker != std::string::npos && text.find("VM service") != std::string::npos) {
    std::string uri = text.substr(marker + sizeof(kVmServiceMarker) - 1);
    while (!uri.empty() && (uri.back() == '\n' || uri.back() == ' ')) uri.pop_back();
    {
      std::lock_guard<std::mutex> lock(host->mutex_);
      host->vm_service_uri_ = uri;
    }
    if (host->on_wake_) host->on_wake_();
  }
  if (host->on_log_) host->on_log_(tag == nullptr ? "" : tag, text);
}

}  // namespace raccoon
