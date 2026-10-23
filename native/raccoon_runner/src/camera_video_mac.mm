// A video as the camera's source on macOS: AVFoundation's asset reader
// decodes it to BGRA, a frame at a time as it comes due; a new reader starts
// it again at its end, as a reader reads once.
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <cstring>

#include "camera_source.h"

namespace raccoon {

namespace {

class VideoSource : public LoopingVideo {
 public:
  bool Open(const std::string& path, std::string* error) {
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    asset_ = [AVURLAsset URLAssetWithURL:url options:nil];
    // The asset's track and duration, read synchronously: the loop thread
    // waits for them either way, and the asynchronous loaders need a run
    // loop or a task to wait on.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<AVAssetTrack*>* tracks = [asset_ tracksWithMediaType:AVMediaTypeVideo];
    const CMTime duration = asset_.duration;
#pragma clang diagnostic pop
    if (tracks.count == 0) {
      *error = "not a video AVFoundation can open";
      return false;
    }
    track_ = tracks.firstObject;
    if (CMTIME_IS_NUMERIC(duration)) {
      duration_micros_ = static_cast<int64_t>(CMTimeGetSeconds(duration) * 1e6);
    }
    if (!StartReader(error)) return false;
    if (!Begin()) {
      *error = "no frame in it";
      return false;
    }
    return true;
  }

 private:
  bool StartReader(std::string* error) {
    NSError* failure = nil;
    reader_ = [AVAssetReader assetReaderWithAsset:asset_ error:&failure];
    if (reader_ == nil) {
      *error = std::string("no reader for it (") +
               (failure ? failure.localizedDescription.UTF8String : "unknown") + ")";
      return false;
    }
    NSDictionary* settings = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    };
    output_ = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track_
                                                         outputSettings:settings];
    output_.alwaysCopiesSampleData = NO;
    if (![reader_ canAddOutput:output_]) {
      *error = "no BGRA output for its video";
      return false;
    }
    [reader_ addOutput:output_];
    if (![reader_ startReading]) {
      *error = "it does not decode";
      return false;
    }
    return true;
  }

  void Restart() override {
    [reader_ cancelReading];
    std::string ignored;
    StartReader(&ignored);
  }

  bool ReadNext(CameraPicture* frame, int64_t* time_micros) override {
    for (;;) {
      if (reader_.status != AVAssetReaderStatusReading) return false;
      CMSampleBufferRef sample = [output_ copyNextSampleBuffer];
      if (sample == nullptr) return false;
      CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
      // A sample without a picture, such as a marker; read on.
      if (image == nullptr) {
        CFRelease(sample);
        continue;
      }
      const CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
      CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
      const size_t width = CVPixelBufferGetWidth(image);
      const size_t height = CVPixelBufferGetHeight(image);
      const size_t stride = CVPixelBufferGetBytesPerRow(image);
      const auto* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(image));
      frame->width = width;
      frame->height = height;
      frame->bgra.resize(width * height * 4);
      for (size_t y = 0; y < height; ++y) {
        std::memcpy(frame->bgra.data() + y * width * 4, base + y * stride, width * 4);
      }
      CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
      CFRelease(sample);
      for (size_t i = 3; i < frame->bgra.size(); i += 4) frame->bgra[i] = 255;
      *time_micros = static_cast<int64_t>(CMTimeGetSeconds(time) * 1e6);
      return true;
    }
  }

  AVURLAsset* asset_ = nil;
  AVAssetTrack* track_ = nil;
  AVAssetReader* reader_ = nil;
  AVAssetReaderTrackOutput* output_ = nil;
};

}  // namespace

std::unique_ptr<CameraSource> OpenCameraVideo(const std::string& path, std::string* error) {
  @autoreleasepool {
    auto video = std::make_unique<VideoSource>();
    if (!video->Open(path, error)) return nullptr;
    return video;
  }
}

}  // namespace raccoon
