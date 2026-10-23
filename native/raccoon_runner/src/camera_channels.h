#pragma once

// The camera plugin's method channels, answered by the runner from a test
// pattern.
//
// `camera` ships no desktop implementation, so on Raccoon it falls back to
// camera_platform_interface's method channel one, which these answer: the
// cameras (one back, one front), pictures (the current frame as a JPEG in
// the temp directory) and image streams (frames in the format the app asked
// for). The camera sees a test pattern, or a picture or video given as its
// source. Video recordings encode what it shows to an MP4, on Windows (see
// camera_recorder.h). A camera's events and the stream's and recording's
// frames go out from the loop, through Service. The preview is a Texture by
// camera id, filled through the renderer's external textures when it has
// them.
//
// Channels: plugins.flutter.io/camera, plugins.flutter.io/camera/imageStream
// (the event channel's listen and cancel).

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "camera_recorder.h"
#include "camera_source.h"
#include "standard_codec.h"

namespace raccoon {

class CameraChannels {
 public:
  using Send = std::function<void(const std::string& channel, std::vector<uint8_t> message)>;

  // Microseconds on the engine's clock, which Service is given too.
  using Clock = std::function<uint64_t()>;

  // Where messages to the app go, from Service.
  void SetSend(Send send) { send_ = std::move(send); }
  // A camera's preview frame: the camera's size turned to portrait, as a
  // phone's preview is while held upright, which is how CameraPreview draws
  // it until the app hears otherwise. BGRA, rows of |width| * 4 bytes;
  // |number| changes with every frame.
  struct Preview {
    size_t width = 0;
    size_t height = 0;
    uint64_t number = 0;
    std::vector<uint8_t> bgra;
  };
  // The engine's external textures, which previews go through: |add| takes
  // an id and says whether the engine took it, |frame| says a new preview is
  // ready, |remove| lets the id go.
  struct Textures {
    std::function<bool(int64_t id)> add;
    std::function<void(int64_t id)> frame;
    std::function<void(int64_t id)> remove;
  };

  // Where previews go; without, a camera has none.
  void SetTextures(Textures textures) { textures_ = std::move(textures); }
  // What time it is when a call comes: a recording paused or started, a
  // picture taken.
  void SetClock(Clock clock) { clock_ = std::move(clock); }
  // Where pictures go; the system's temp directory until set.
  void SetPictureDirectory(std::string directory) { pictures_ = std::move(directory); }
  // Shows the PNG, JPEG or video at |path| in place of the test pattern;
  // false with |error| set when it does not open.
  bool SetSource(const std::string& path, std::string* error);

  // Answers a message on one of the camera channels into |reply| and returns
  // true; returns false for any other channel. An empty reply is a method the
  // plugin does not have.
  bool Handle(const std::string& channel, const uint8_t* data, size_t size,
              std::vector<uint8_t>* reply);

  // Camera |id|'s latest preview, null for none, and a note that something
  // drew it. From any thread: the renderer asks on its raster thread, and
  // only while the texture is drawn.
  std::shared_ptr<const Preview> PreviewOf(int64_t id);

  // Sends what is due at |now_micros|: events, previews, then the stream's
  // next frame.
  // From the loop, every iteration.
  void Service(uint64_t now_micros);
  // Milliseconds until Service has something to do; -1 for nothing.
  int MillisUntilDue(uint64_t now_micros) const;

  // The test pattern at |time_micros|: colour bars over the top three
  // quarters, a white block moving along the black bottom quarter. BGRA,
  // rows of |width| * 4 bytes.
  static std::vector<uint8_t> Pattern(size_t width, size_t height, uint64_t time_micros);

 private:
  struct Camera {
    size_t width = 0;
    size_t height = 0;
    int fps = 30;
    // ImageFormatGroup's name, from initialize.
    std::string format;
    bool initialized = false;
    // Its preview goes to the texture by its id, unless paused.
    bool previewing = false;
    bool paused = false;
    uint64_t next_preview_micros = 0;
    // Preview frames in a row that nothing drew.
    int undrawn = 0;
  };

  // What the camera sees at |time_micros|, at |width| x |height|: the
  // source's frame when there is one, the test pattern otherwise.
  std::vector<uint8_t> Frame(size_t width, size_t height, uint64_t time_micros);
  CodecValue Call(const MethodCall& call, bool* known, std::string* error);
  CodecValue Create(const CodecValue& args);
  CodecValue TakePicture(int64_t id, std::string* error);
  CodecValue StartRecording(const CodecValue& args, std::string* error);
  CodecValue StopRecording(std::string* error);
  // Writes the recording's next frame when it is due.
  void ServiceRecording(uint64_t now_micros);
  // Ends the recording and returns its path; empty with |error| set when it
  // could not be finished.
  std::string FinishRecording(std::string* error);
  // A new file for |extension| in the pictures' directory.
  std::string NewFilePath(const char* extension);
  // The stream's frame at |now_micros| in its camera's format.
  CodecValue StreamFrame(const Camera& camera, uint64_t now_micros);
  Camera* Find(const CodecValue& args);
  // Makes camera |id|'s preview at |now_micros| when one is due.
  void ServicePreview(int64_t id, Camera& camera, uint64_t now_micros);
  void StopPreview(int64_t id, Camera& camera);
  uint64_t Now() const { return clock_ ? clock_() : 0; }

  Send send_;
  std::string pictures_;
  std::unique_ptr<CameraSource> source_;
  // The source's latest frame fitted to each size asked for, by its number.
  std::map<std::pair<size_t, size_t>, std::pair<uint64_t, std::vector<uint8_t>>> fitted_;
  // CameraPreview draws Texture(textureId: cameraId), so a camera's id is
  // its texture's. From 2^48 + 1, clear of the plugins' textures: counted
  // from 1 on macOS, pointers on Linux.
  int64_t next_id_ = (int64_t{1} << 48) + 1;
  Textures textures_;
  // A camera's latest preview, and whether the renderer took it.
  struct PreviewSlot {
    std::shared_ptr<const Preview> frame;
    bool drawn = true;
  };
  std::mutex previews_mutex_;
  std::map<int64_t, PreviewSlot> previews_;
  uint64_t previews_made_ = 0;
  uint64_t pictures_taken_ = 0;
  // The recording under way: the camera's frames into |recorder|, on a grid
  // at the camera's fps, its times less the time spent paused.
  struct Recording {
    int64_t camera = 0;
    std::unique_ptr<CameraRecorder> recorder;
    std::string path;
    uint64_t started_micros = 0;
    uint64_t paused_micros = 0;
    uint64_t paused_at_micros = 0;
    bool paused = false;
    uint64_t next_frame_micros = 0;
  };
  std::unique_ptr<Recording> recording_;
  int jpeg_quality_ = 90;
  std::map<int64_t, Camera> cameras_;
  // Messages for the app, channel and bytes, sent on the next Service.
  std::vector<std::pair<std::string, std::vector<uint8_t>>> pending_;
  // The stream runs while the app asked for it and listens to it; it shows
  // the camera initialized last, as the method channel names none.
  bool streaming_ = false;
  bool listening_ = false;
  int64_t stream_camera_ = 0;
  uint64_t next_frame_micros_ = 0;
  Clock clock_;
};

}  // namespace raccoon
