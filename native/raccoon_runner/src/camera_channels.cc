#include "camera_channels.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <system_error>

#if defined(_WIN32)
#include <process.h>
#else
#include <unistd.h>
#endif

#include "jpeg_encoder.h"

namespace raccoon {

namespace {

constexpr char kCamera[] = "plugins.flutter.io/camera";
constexpr char kImageStream[] = "plugins.flutter.io/camera/imageStream";

constexpr char kBackCamera[] = "Raccoon back camera";
constexpr char kFrontCamera[] = "Raccoon front camera";

// The raw formats a stream's frames say they are in: Android's
// ImageFormat.YUV_420_888 and JPEG, Core Video's 32BGRA.
constexpr int64_t kRawYuv420 = 35;
constexpr int64_t kRawJpeg = 256;
constexpr int64_t kRawBgra = 1111970369;

int ProcessId() {
#if defined(_WIN32)
  return _getpid();
#else
  return static_cast<int>(getpid());
#endif
}

// A resolution preset's size; max stops at 1920x1080 too, so streams stay
// affordable.
std::pair<size_t, size_t> PresetSize(const CodecValue& preset) {
  const std::string name =
      preset.type() == CodecValue::Type::kString ? preset.string_value() : "high";
  if (name == "low") return {352, 288};
  if (name == "medium") return {640, 480};
  if (name == "high") return {1280, 720};
  return {1920, 1080};
}

// When the next frame is due after one due at |due|: on a grid of
// |interval|, as vsync is; after a stall the grid starts again from |now|.
uint64_t NextDue(uint64_t due, uint64_t now, uint64_t interval) {
  return now - due > interval ? now + interval : due + interval;
}

CodecValue Plane(std::vector<uint8_t> bytes, size_t bytes_per_row, int64_t bytes_per_pixel,
                 size_t width, size_t height) {
  return CodecValue::Map({
      {"bytes", CodecValue::Bytes(std::move(bytes))},
      {"bytesPerRow", CodecValue::Int(static_cast<int64_t>(bytes_per_row))},
      {"bytesPerPixel", CodecValue::Int(bytes_per_pixel)},
      {"width", CodecValue::Int(static_cast<int64_t>(width))},
      {"height", CodecValue::Int(static_cast<int64_t>(height))},
  });
}

}  // namespace

std::vector<uint8_t> CameraChannels::Pattern(size_t width, size_t height,
                                             uint64_t time_micros) {
  // White, yellow, cyan, green, magenta, red, blue; as B, G, R.
  static constexpr uint8_t kBars[7][3] = {{255, 255, 255}, {0, 255, 255}, {255, 255, 0},
                                          {0, 255, 0},     {255, 0, 255}, {0, 0, 255},
                                          {255, 0, 0}};
  std::vector<uint8_t> pixels(width * height * 4);
  const size_t bars_end = height * 3 / 4;
  // The block crosses the frame once every two seconds.
  const size_t block = std::max<size_t>(width / 8, 1);
  const size_t block_x = static_cast<size_t>((time_micros / 1000) % 2000 * (width + block) / 2000);
  for (size_t y = 0; y < height; ++y) {
    uint8_t* row = pixels.data() + y * width * 4;
    for (size_t x = 0; x < width; ++x) {
      uint8_t* pixel = row + x * 4;
      if (y < bars_end) {
        const uint8_t* bar = kBars[std::min<size_t>(x * 7 / width, 6)];
        pixel[0] = bar[0];
        pixel[1] = bar[1];
        pixel[2] = bar[2];
      } else {
        const bool lit = x + block >= block_x && x < block_x;
        pixel[0] = pixel[1] = pixel[2] = lit ? 255 : 0;
      }
      pixel[3] = 255;
    }
  }
  return pixels;
}

bool CameraChannels::SetSource(const std::string& path, std::string* error) {
  std::unique_ptr<CameraSource> source = OpenCameraSource(path, error);
  if (!source) return false;
  source_ = std::move(source);
  fitted_.clear();
  return true;
}

std::vector<uint8_t> CameraChannels::Frame(size_t width, size_t height, uint64_t time_micros) {
  if (!source_) return Pattern(width, height, time_micros);
  uint64_t number = 0;
  const CameraPicture* frame = source_->FrameAt(time_micros, &number);
  if (frame == nullptr) return Pattern(width, height, time_micros);
  auto [found, added] = fitted_.try_emplace({width, height});
  if (added || found->second.first != number) {
    found->second = {number, FitCameraPicture(*frame, width, height)};
  }
  return found->second.second;
}

bool CameraChannels::Handle(const std::string& channel, const uint8_t* data, size_t size,
                            std::vector<uint8_t>* reply) {
  if (channel != kCamera && channel != kImageStream) return false;
  MethodCall call;
  if (!DecodeMethodCall(data, size, &call)) {
    *reply = EncodeError("bad-call", "raccoon_runner could not decode a " + channel +
                                         " method call");
    return true;
  }
  if (std::getenv("RACCOON_TRACE") != nullptr) {
    std::fprintf(stderr, "🦝 %s.%s\n", channel.c_str(), call.method.c_str());
  }
  if (channel == kImageStream) {
    // The event channel: listen and cancel, each answered with success.
    if (call.method == "listen") {
      listening_ = true;
    } else if (call.method == "cancel") {
      listening_ = false;
    } else {
      reply->clear();
      return true;
    }
    *reply = EncodeSuccess(CodecValue());
    return true;
  }
  bool known = true;
  std::string error;
  const CodecValue result = Call(call, &known, &error);
  if (!known) {
    reply->clear();
    return true;
  }
  if (!error.empty()) {
    const size_t colon = error.find(':');
    *reply = EncodeError(error.substr(0, colon), error.substr(colon + 2));
    return true;
  }
  *reply = EncodeSuccess(result);
  return true;
}

CameraChannels::Camera* CameraChannels::Find(const CodecValue& args) {
  const auto found = cameras_.find(args.Get("cameraId").int_value());
  return found == cameras_.end() ? nullptr : &found->second;
}

CodecValue CameraChannels::Call(const MethodCall& call, bool* known, std::string* error) {
  const std::string& method = call.method;
  const CodecValue& args = call.arguments;
  if (method == "availableCameras") {
    auto Description = [](const char* name, const char* facing) {
      return CodecValue::Map({
          {"name", CodecValue::String(name)},
          {"lensFacing", CodecValue::String(facing)},
          {"sensorOrientation", CodecValue::Int(0)},
      });
    };
    return CodecValue::List(
        {Description(kBackCamera, "back"), Description(kFrontCamera, "front")});
  }
  if (method == "create") return Create(args);
  if (method == "initialize") {
    Camera* camera = Find(args);
    if (camera == nullptr) {
      *error = "CameraAccess: no camera with that id";
      return CodecValue();
    }
    const CodecValue& format = args.Get("imageFormatGroup");
    camera->format = format.type() == CodecValue::Type::kString ? format.string_value() : "";
    camera->initialized = true;
    stream_camera_ = args.Get("cameraId").int_value();
    if (!camera->previewing && textures_.add && textures_.add(stream_camera_)) {
      camera->previewing = true;
      camera->next_preview_micros = 0;
    }
    pending_.emplace_back(
        "flutter.io/cameraPlugin/camera" + std::to_string(stream_camera_),
        EncodeMethodCall("initialized",
                         CodecValue::Map({
                             {"previewWidth", CodecValue::Double(static_cast<double>(camera->width))},
                             {"previewHeight", CodecValue::Double(static_cast<double>(camera->height))},
                             {"exposureMode", CodecValue::String("auto")},
                             {"exposurePointSupported", CodecValue::Bool(false)},
                             {"focusMode", CodecValue::String("auto")},
                             {"focusPointSupported", CodecValue::Bool(false)},
                         })));
    return CodecValue();
  }
  if (method == "dispose") {
    const int64_t id = args.Get("cameraId").int_value();
    if (Camera* camera = Find(args)) StopPreview(id, *camera);
    cameras_.erase(id);
    if (id == stream_camera_) streaming_ = false;
    return CodecValue();
  }
  if (method == "takePicture") return TakePicture(args.Get("cameraId").int_value(), error);
  if (method == "startImageStream") {
    if (cameras_.count(stream_camera_) == 0) {
      *error = "CameraNotInitialized: no camera to stream from";
      return CodecValue();
    }
    streaming_ = true;
    next_frame_micros_ = 0;
    return CodecValue();
  }
  if (method == "stopImageStream") {
    streaming_ = false;
    return CodecValue();
  }
  if (method == "prepareForVideoRecording") return CodecValue();
  if (method == "startVideoRecording" || method == "setDescriptionWhileRecording") {
    *error = "unsupported: Raccoon's test camera records no video yet";
    return CodecValue();
  }
  if (method == "setJpegImageQuality") {
    jpeg_quality_ = static_cast<int>(std::clamp<int64_t>(args.Get("quality").int_value(), 1, 100));
    return CodecValue();
  }
  // A fixed lens: no exposure offset, no zoom.
  if (method == "getMinExposureOffset" || method == "getMaxExposureOffset" ||
      method == "getExposureOffsetStepSize" || method == "setExposureOffset") {
    return CodecValue::Double(0);
  }
  if (method == "getMinZoomLevel" || method == "getMaxZoomLevel") return CodecValue::Double(1);
  if (method == "setZoomLevel") {
    if (args.Get("zoom").AsDouble(1) != 1) {
      *error = "ZOOM_ERROR: zoom level out of bounds (1 to 1)";
    }
    return CodecValue();
  }
  if (method == "pausePreview" || method == "resumePreview") {
    if (Camera* camera = Find(args)) {
      camera->paused = method == "pausePreview";
      camera->next_preview_micros = 0;
    }
    return CodecValue();
  }
  // Accepted and changing nothing.
  if (method == "lockCaptureOrientation" || method == "unlockCaptureOrientation" ||
      method == "setFlashMode" || method == "setExposureMode" ||
      method == "setExposurePoint" || method == "setFocusMode" ||
      method == "setFocusPoint" || method == "setImageFileFormat" || method == "receivedImageStreamData") {
    return CodecValue();
  }
  *known = false;
  return CodecValue();
}

CodecValue CameraChannels::Create(const CodecValue& args) {
  Camera camera;
  const auto [width, height] = PresetSize(args.Get("resolutionPreset"));
  camera.width = width;
  camera.height = height;
  const CodecValue& fps = args.Get("fps");
  if (fps.type() == CodecValue::Type::kInt && fps.int_value() > 0) {
    camera.fps = static_cast<int>(std::min<int64_t>(fps.int_value(), 30));
  }
  const int64_t id = next_id_++;
  cameras_[id] = camera;
  return CodecValue::Map({{"cameraId", CodecValue::Int(id)}});
}

CodecValue CameraChannels::TakePicture(int64_t id, std::string* error) {
  const auto found = cameras_.find(id);
  if (found == cameras_.end() || !found->second.initialized) {
    *error = "CameraNotInitialized: the camera is not initialized";
    return CodecValue();
  }
  const Camera& camera = found->second;
  const std::vector<uint8_t> pixels = Frame(camera.width, camera.height, now_micros_);
  const std::vector<uint8_t> jpeg =
      EncodeJpeg(pixels.data(), camera.width, camera.height, camera.width * 4, jpeg_quality_);
  std::error_code code;
  const std::filesystem::path directory = pictures_.empty()
                                              ? std::filesystem::temp_directory_path(code)
                                              : std::filesystem::u8path(pictures_);
  std::filesystem::create_directories(directory, code);
  const std::filesystem::path path =
      directory / ("raccoon_camera_" + std::to_string(ProcessId()) + "_" +
                   std::to_string(++pictures_taken_) + ".jpg");
  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  file.write(reinterpret_cast<const char*>(jpeg.data()), static_cast<std::streamsize>(jpeg.size()));
  file.close();
  if (!file) {
    *error = "IOError: could not write " + path.u8string();
    return CodecValue();
  }
  return CodecValue::String(path.u8string());
}

CodecValue CameraChannels::StreamFrame(const Camera& camera, uint64_t now_micros) {
  const size_t width = camera.width;
  const size_t height = camera.height;
  const std::vector<uint8_t> bgra = Frame(width, height, now_micros);
  int64_t raw = kRawBgra;
  std::vector<CodecValue> planes;
  if (camera.format == "yuv420") {
    // I420, BT.601 video range: a full Y plane, then U and V at half size
    // each way, each sample the average of its four pixels.
    raw = kRawYuv420;
    const size_t chroma_width = (width + 1) / 2;
    const size_t chroma_height = (height + 1) / 2;
    std::vector<uint8_t> y_plane(width * height);
    std::vector<uint8_t> u_plane(chroma_width * chroma_height);
    std::vector<uint8_t> v_plane(chroma_width * chroma_height);
    for (size_t y = 0; y < height; ++y) {
      for (size_t x = 0; x < width; ++x) {
        const uint8_t* p = bgra.data() + (y * width + x) * 4;
        y_plane[y * width + x] =
            static_cast<uint8_t>(((66 * p[2] + 129 * p[1] + 25 * p[0] + 128) >> 8) + 16);
      }
    }
    for (size_t cy = 0; cy < chroma_height; ++cy) {
      for (size_t cx = 0; cx < chroma_width; ++cx) {
        int r = 0, g = 0, b = 0;
        for (size_t dy = 0; dy < 2; ++dy) {
          for (size_t dx = 0; dx < 2; ++dx) {
            const size_t x = std::min(cx * 2 + dx, width - 1);
            const size_t y = std::min(cy * 2 + dy, height - 1);
            const uint8_t* p = bgra.data() + (y * width + x) * 4;
            b += p[0];
            g += p[1];
            r += p[2];
          }
        }
        r /= 4;
        g /= 4;
        b /= 4;
        u_plane[cy * chroma_width + cx] =
            static_cast<uint8_t>(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
        v_plane[cy * chroma_width + cx] =
            static_cast<uint8_t>(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
      }
    }
    planes.push_back(Plane(std::move(y_plane), width, 1, width, height));
    planes.push_back(Plane(std::move(u_plane), chroma_width, 1, chroma_width, chroma_height));
    planes.push_back(Plane(std::move(v_plane), chroma_width, 1, chroma_width, chroma_height));
  } else if (camera.format == "jpeg") {
    raw = kRawJpeg;
    std::vector<uint8_t> jpeg = EncodeJpeg(bgra.data(), width, height, width * 4, jpeg_quality_);
    const size_t size = jpeg.size();
    planes.push_back(Plane(std::move(jpeg), size, 1, width, height));
  } else {
    planes.push_back(Plane(std::vector<uint8_t>(bgra), width * 4, 4, width, height));
  }
  return CodecValue::Map({
      {"width", CodecValue::Int(static_cast<int64_t>(width))},
      {"height", CodecValue::Int(static_cast<int64_t>(height))},
      {"format", CodecValue::Int(raw)},
      {"planes", CodecValue::List(std::move(planes))},
  });
}

void CameraChannels::Service(uint64_t now_micros) {
  now_micros_ = now_micros;
  if (!send_) return;
  for (auto& [channel, message] : pending_) send_(channel, std::move(message));
  pending_.clear();
  for (auto& [id, camera] : cameras_) ServicePreview(id, camera, now_micros);
  if (!streaming_ || !listening_) return;
  const auto found = cameras_.find(stream_camera_);
  if (found == cameras_.end()) return;
  if (now_micros < next_frame_micros_) return;
  next_frame_micros_ = NextDue(next_frame_micros_, now_micros,
                               1000000 / static_cast<uint64_t>(found->second.fps));
  send_(kImageStream, EncodeSuccess(StreamFrame(found->second, now_micros)));
}

void CameraChannels::ServicePreview(int64_t id, Camera& camera, uint64_t now_micros) {
  if (!camera.previewing || camera.paused || now_micros < camera.next_preview_micros) return;
  camera.next_preview_micros = NextDue(camera.next_preview_micros, now_micros,
                                       1000000 / static_cast<uint64_t>(camera.fps));
  auto preview = std::make_shared<Preview>();
  preview->width = camera.height;
  preview->height = camera.width;
  preview->number = ++previews_made_;
  preview->bgra = Frame(preview->width, preview->height, now_micros);
  {
    std::lock_guard<std::mutex> lock(previews_mutex_);
    previews_[id] = std::move(preview);
  }
  textures_.frame(id);
}

void CameraChannels::StopPreview(int64_t id, Camera& camera) {
  if (!camera.previewing) return;
  camera.previewing = false;
  {
    std::lock_guard<std::mutex> lock(previews_mutex_);
    previews_.erase(id);
  }
  textures_.remove(id);
}

std::shared_ptr<const CameraChannels::Preview> CameraChannels::PreviewOf(int64_t id) const {
  std::lock_guard<std::mutex> lock(previews_mutex_);
  const auto found = previews_.find(id);
  return found == previews_.end() ? nullptr : found->second;
}

int CameraChannels::MillisUntilDue(uint64_t now_micros) const {
  if (!pending_.empty()) return 0;
  uint64_t due = std::numeric_limits<uint64_t>::max();
  for (const auto& [id, camera] : cameras_) {
    if (camera.previewing && !camera.paused) due = std::min(due, camera.next_preview_micros);
  }
  if (streaming_ && listening_ && cameras_.count(stream_camera_) != 0) {
    due = std::min(due, next_frame_micros_);
  }
  if (due == std::numeric_limits<uint64_t>::max()) return -1;
  if (due <= now_micros) return 0;
  return static_cast<int>((due - now_micros + 999) / 1000);
}

}  // namespace raccoon
