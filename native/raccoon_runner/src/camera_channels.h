#pragma once

// The camera plugin's method channels, answered by the runner from a test
// pattern.
//
// `camera` ships no desktop implementation, so on Raccoon it falls back to
// camera_platform_interface's method channel one, which these answer: the
// cameras (one back, one front), pictures (the current frame as a JPEG in
// the temp directory) and image streams (frames in the format the app asked
// for). The camera sees a test pattern, or a picture or video given as its
// source. A camera's 'initialized' event and the stream's frames go to the app
// from the loop, through Service. The preview is a Texture by camera id that
// nothing fills yet; video recording is refused.
//
// Channels: plugins.flutter.io/camera, plugins.flutter.io/camera/imageStream
// (the event channel's listen and cancel).

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "camera_source.h"
#include "standard_codec.h"

namespace raccoon {

class CameraChannels {
 public:
  using Send = std::function<void(const std::string& channel, std::vector<uint8_t> message)>;

  // Where messages to the app go, from Service.
  void SetSend(Send send) { send_ = std::move(send); }
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

  // Sends what is due at |now_micros|: events, then the stream's next frame.
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
  };

  // What the camera sees at |time_micros|, at |width| x |height|: the
  // source's frame when there is one, the test pattern otherwise.
  std::vector<uint8_t> Frame(size_t width, size_t height, uint64_t time_micros);
  CodecValue Call(const MethodCall& call, bool* known, std::string* error);
  CodecValue Create(const CodecValue& args);
  CodecValue TakePicture(int64_t id, std::string* error);
  // The stream's frame at |now_micros| in its camera's format.
  CodecValue StreamFrame(const Camera& camera, uint64_t now_micros);
  Camera* Find(const CodecValue& args);

  Send send_;
  std::string pictures_;
  std::unique_ptr<CameraSource> source_;
  // The source's latest frame fitted to each size asked for, by its number.
  std::map<std::pair<size_t, size_t>, std::pair<uint64_t, std::vector<uint8_t>>> fitted_;
  int64_t next_id_ = 1;
  uint64_t pictures_taken_ = 0;
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
  // The clock the pattern moves by: microseconds since the first call.
  uint64_t now_micros_ = 0;
};

}  // namespace raccoon
