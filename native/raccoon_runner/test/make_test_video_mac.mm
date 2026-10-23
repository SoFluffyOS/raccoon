// make_test_video.cc for macOS, with AVFoundation: writes the camera tests'
// video (160x120 H.264 in MP4, 30 fps, a third of a second, red and green
// over blue and yellow in every frame) or says what a video holds.
//
//   raccoon_test_video OUT.mp4
//   raccoon_test_video --probe VIDEO
//     frames=N size=WxH duration_ms=D left=R,G,B right=R,G,B
//     (the first frame's colours a quarter down, a fourteenth of its width
//     in from each side)
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <cstdio>
#include <cstring>

namespace {

constexpr size_t kWidth = 160;
constexpr size_t kHeight = 120;
constexpr int kFps = 30;
constexpr int kFrames = 10;

// The quadrant colours, as B, G, R, into rows of |stride| bytes.
void Fill(uint8_t* pixels, size_t stride) {
  for (size_t y = 0; y < kHeight; ++y) {
    for (size_t x = 0; x < kWidth; ++x) {
      uint8_t* p = pixels + y * stride + x * 4;
      const bool right = x >= kWidth / 2;
      const bool bottom = y >= kHeight / 2;
      uint8_t r = 0, g = 0, b = 0;
      if (!bottom && !right) r = 220, g = 20, b = 30;
      if (!bottom && right) r = 20, g = 200, b = 40;
      if (bottom && !right) r = 30, g = 40, b = 220;
      if (bottom && right) r = 230, g = 210, b = 20;
      p[0] = b;
      p[1] = g;
      p[2] = r;
      p[3] = 255;
    }
  }
}

int WriteVideo(NSURL* url) {
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
  NSError* failure = nil;
  AVAssetWriter* writer = [AVAssetWriter assetWriterWithURL:url
                                                   fileType:AVFileTypeMPEG4
                                                      error:&failure];
  if (writer == nil) {
    std::fprintf(stderr, "raccoon_test_video: %s\n", failure.localizedDescription.UTF8String);
    return 1;
  }
  AVAssetWriterInput* input = [AVAssetWriterInput
      assetWriterInputWithMediaType:AVMediaTypeVideo
                     outputSettings:@{
                       AVVideoCodecKey : AVVideoCodecTypeH264,
                       AVVideoWidthKey : @(kWidth),
                       AVVideoHeightKey : @(kHeight),
                     }];
  AVAssetWriterInputPixelBufferAdaptor* adaptor = [AVAssetWriterInputPixelBufferAdaptor
      assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                 sourcePixelBufferAttributes:@{
                                   (id)kCVPixelBufferPixelFormatTypeKey :
                                       @(kCVPixelFormatType_32BGRA),
                                   (id)kCVPixelBufferWidthKey : @(kWidth),
                                   (id)kCVPixelBufferHeightKey : @(kHeight),
                                 }];
  [writer addInput:input];
  if (![writer startWriting]) {
    std::fprintf(stderr, "raccoon_test_video: startWriting failed\n");
    return 1;
  }
  [writer startSessionAtSourceTime:kCMTimeZero];
  for (int i = 0; i < kFrames; ++i) {
    while (!input.readyForMoreMediaData) [NSThread sleepForTimeInterval:0.01];
    CVPixelBufferRef buffer = nullptr;
    CVPixelBufferPoolCreatePixelBuffer(nullptr, adaptor.pixelBufferPool, &buffer);
    if (buffer == nullptr) return 1;
    CVPixelBufferLockBaseAddress(buffer, 0);
    Fill(static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer)),
         CVPixelBufferGetBytesPerRow(buffer));
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    const BOOL appended = [adaptor appendPixelBuffer:buffer
                                withPresentationTime:CMTimeMake(i, kFps)];
    CVPixelBufferRelease(buffer);
    if (!appended) return 1;
  }
  [input markAsFinished];
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [writer finishWritingWithCompletionHandler:^{
    dispatch_semaphore_signal(done);
  }];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  return writer.status == AVAssetWriterStatusCompleted ? 0 : 1;
}

int ProbeVideo(NSURL* url) {
  AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSArray<AVAssetTrack*>* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
  const CMTime duration = asset.duration;
#pragma clang diagnostic pop
  if (tracks.count == 0) return 1;
  NSError* failure = nil;
  AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:&failure];
  AVAssetReaderTrackOutput* output = [AVAssetReaderTrackOutput
      assetReaderTrackOutputWithTrack:tracks.firstObject
                       outputSettings:@{
                         (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                       }];
  [reader addOutput:output];
  if (![reader startReading]) return 1;
  int frames = 0;
  size_t width = 0;
  size_t height = 0;
  uint8_t left[3] = {};
  uint8_t right[3] = {};
  for (;;) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == nullptr) break;
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (image != nullptr && frames++ == 0) {
      CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
      width = CVPixelBufferGetWidth(image);
      height = CVPixelBufferGetHeight(image);
      const size_t stride = CVPixelBufferGetBytesPerRow(image);
      const auto* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(image));
      const uint8_t* row = base + (height / 4) * stride;
      const uint8_t* l = row + (width / 14) * 4;
      const uint8_t* r = row + (width * 13 / 14) * 4;
      for (int i = 0; i < 3; ++i) {
        left[i] = l[2 - i];
        right[i] = r[2 - i];
      }
      CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    }
    CFRelease(sample);
  }
  std::printf("frames=%d size=%zux%zu duration_ms=%lld left=%u,%u,%u right=%u,%u,%u\n", frames,
              width, height, static_cast<long long>(CMTimeGetSeconds(duration) * 1000),
              left[0], left[1], left[2], right[0], right[1], right[2]);
  return frames > 0 ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    const bool probe = argc == 3 && std::strcmp(argv[1], "--probe") == 0;
    if (argc != 2 && !probe) {
      std::fprintf(stderr, "usage: raccoon_test_video OUT.mp4 | --probe VIDEO\n");
      return 2;
    }
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[probe ? 2 : 1]]];
    return probe ? ProbeVideo(url) : WriteVideo(url);
  }
}
