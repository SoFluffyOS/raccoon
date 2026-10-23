// The camera's recordings on macOS: AVFoundation's asset writer takes BGRA
// frames through a pixel buffer adaptor and encodes them to H.264 in an MP4.
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <cstring>

#include "camera_recorder.h"

namespace raccoon {

namespace {

class AVFoundationRecorder : public CameraRecorder {
 public:
  bool Start(const std::string& path, size_t width, size_t height, std::string* error) {
    width_ = width;
    height_ = height;
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    // The writer will not replace a file.
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    NSError* failure = nil;
    writer_ = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:&failure];
    if (writer_ == nil) {
      *error = std::string("could not create the file (") +
               (failure ? failure.localizedDescription.UTF8String : "unknown") + ")";
      return false;
    }
    NSDictionary* settings = @{
      AVVideoCodecKey : AVVideoCodecTypeH264,
      AVVideoWidthKey : @(width),
      AVVideoHeightKey : @(height),
    };
    input_ = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                outputSettings:settings];
    input_.expectsMediaDataInRealTime = YES;
    NSDictionary* buffers = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
      (id)kCVPixelBufferWidthKey : @(width),
      (id)kCVPixelBufferHeightKey : @(height),
    };
    adaptor_ = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input_
                                   sourcePixelBufferAttributes:buffers];
    if (![writer_ canAddInput:input_]) {
      *error = "no H.264 input for the file";
      return false;
    }
    [writer_ addInput:input_];
    if (![writer_ startWriting]) {
      *error = std::string("no H.264 encoder took the frames (") +
               (writer_.error ? writer_.error.localizedDescription.UTF8String : "unknown") + ")";
      return false;
    }
    [writer_ startSessionAtSourceTime:kCMTimeZero];
    return true;
  }

  bool Write(const uint8_t* bgra, uint64_t time_micros) override {
    @autoreleasepool {
      // A frame the encoder is not ready for is dropped, as a camera drops
      // one.
      if (!input_.readyForMoreMediaData || adaptor_.pixelBufferPool == nullptr) return false;
      CVPixelBufferRef buffer = nullptr;
      if (CVPixelBufferPoolCreatePixelBuffer(nullptr, adaptor_.pixelBufferPool, &buffer) !=
          kCVReturnSuccess) {
        return false;
      }
      CVPixelBufferLockBaseAddress(buffer, 0);
      auto* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
      const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
      for (size_t y = 0; y < height_; ++y) {
        std::memcpy(base + y * stride, bgra + y * width_ * 4, width_ * 4);
      }
      CVPixelBufferUnlockBaseAddress(buffer, 0);
      const BOOL appended =
          [adaptor_ appendPixelBuffer:buffer
                 withPresentationTime:CMTimeMake(static_cast<int64_t>(time_micros), 1000000)];
      CVPixelBufferRelease(buffer);
      return appended;
    }
  }

  bool Finish(std::string* error) override {
    [input_ markAsFinished];
    // The writer finishes on a queue of its own; the loop waits for it.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer_ finishWritingWithCompletionHandler:^{
      dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (writer_.status != AVAssetWriterStatusCompleted) {
      *error = std::string("could not finish the file (") +
               (writer_.error ? writer_.error.localizedDescription.UTF8String : "unknown") + ")";
      return false;
    }
    return true;
  }

 private:
  AVAssetWriter* writer_ = nil;
  AVAssetWriterInput* input_ = nil;
  AVAssetWriterInputPixelBufferAdaptor* adaptor_ = nil;
  size_t width_ = 0;
  size_t height_ = 0;
};

}  // namespace

std::unique_ptr<CameraRecorder> StartCameraRecorder(const std::string& path, size_t width,
                                                    size_t height, int, std::string* error) {
  @autoreleasepool {
    auto recorder = std::make_unique<AVFoundationRecorder>();
    if (!recorder->Start(path, width, height, error)) return nullptr;
    return recorder;
  }
}

}  // namespace raccoon
