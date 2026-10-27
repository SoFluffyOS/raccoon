// The camera's recordings on Windows: Media Foundation's sink writer takes
// BGRA frames and encodes them to H.264 in an MP4.
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>

#include "camera_recorder.h"
#include "media_foundation_win.h"

namespace raccoon {

namespace {

using Microsoft::WRL::ComPtr;

std::string Hresult(const char* what, HRESULT result) {
  char text[64];
  std::snprintf(text, sizeof(text), " (0x%08lx)", static_cast<unsigned long>(result));
  return what + std::string(text);
}

void SetVideoType(IMFMediaType* type, const GUID& subtype, UINT32 width, UINT32 height,
                  UINT32 fps) {
  type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  type->SetGUID(MF_MT_SUBTYPE, subtype);
  type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  MFSetAttributeSize(type, MF_MT_FRAME_SIZE, width, height);
  MFSetAttributeRatio(type, MF_MT_FRAME_RATE, fps, 1);
  MFSetAttributeRatio(type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
}

class MediaFoundationRecorder : public CameraRecorder {
 public:
  ~MediaFoundationRecorder() override {
    writer_.Reset();
    if (started_) MFShutdown();
    if (com_) CoUninitialize();
  }

  bool Start(const std::string& path, size_t width, size_t height, int fps,
             std::string* error) {
    width_ = width;
    height_ = height;
    frame_time_ = 10000000 / fps;
    com_ = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
    if (!MediaFoundationPresent() || FAILED(MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET))) {
      *error = "Media Foundation is not available";
      return false;
    }
    started_ = true;
    const std::wstring wide = std::filesystem::u8path(path).wstring();
    HRESULT result = MFCreateSinkWriterFromURL(wide.c_str(), nullptr, nullptr, &writer_);
    if (FAILED(result)) {
      *error = Hresult("could not create the file", result);
      return false;
    }
    ComPtr<IMFMediaType> output;
    ComPtr<IMFMediaType> input;
    MFCreateMediaType(&output);
    MFCreateMediaType(&input);
    const UINT32 w = static_cast<UINT32>(width);
    const UINT32 h = static_cast<UINT32>(height);
    const UINT32 rate = static_cast<UINT32>(fps);
    SetVideoType(output.Get(), MFVideoFormat_H264, w, h, rate);
    // About a tenth of a bit a pixel a frame: plenty for a test camera.
    output->SetUINT32(MF_MT_AVG_BITRATE, std::max<UINT32>(w * h * rate / 10, 500000));
    SetVideoType(input.Get(), MFVideoFormat_RGB32, w, h, rate);
    // Top-down rows.
    input->SetUINT32(MF_MT_DEFAULT_STRIDE, w * 4);
    result = writer_->AddStream(output.Get(), &stream_);
    if (SUCCEEDED(result)) result = writer_->SetInputMediaType(stream_, input.Get(), nullptr);
    if (SUCCEEDED(result)) result = writer_->BeginWriting();
    if (FAILED(result)) {
      *error = Hresult("no H.264 encoder took the frames", result);
      return false;
    }
    return true;
  }

  bool Write(const uint8_t* bgra, uint64_t time_micros) override {
    const DWORD length = static_cast<DWORD>(width_ * height_ * 4);
    ComPtr<IMFMediaBuffer> buffer;
    ComPtr<IMFSample> sample;
    BYTE* data = nullptr;
    if (FAILED(MFCreateMemoryBuffer(length, &buffer)) ||
        FAILED(buffer->Lock(&data, nullptr, nullptr))) {
      return false;
    }
    std::memcpy(data, bgra, length);
    buffer->Unlock();
    buffer->SetCurrentLength(length);
    if (FAILED(MFCreateSample(&sample))) return false;
    sample->AddBuffer(buffer.Get());
    sample->SetSampleTime(static_cast<LONGLONG>(time_micros) * 10);
    sample->SetSampleDuration(frame_time_);
    return SUCCEEDED(writer_->WriteSample(stream_, sample.Get()));
  }

  bool Finish(std::string* error) override {
    const HRESULT result = writer_->Finalize();
    if (FAILED(result)) {
      *error = Hresult("could not finish the file", result);
      return false;
    }
    return true;
  }

 private:
  bool com_ = false;
  bool started_ = false;
  ComPtr<IMFSinkWriter> writer_;
  DWORD stream_ = 0;
  size_t width_ = 0;
  size_t height_ = 0;
  LONGLONG frame_time_ = 0;
};

}  // namespace

std::unique_ptr<CameraRecorder> StartCameraRecorder(const std::string& path, size_t width,
                                                    size_t height, int fps, std::string* error) {
  auto recorder = std::make_unique<MediaFoundationRecorder>();
  if (!recorder->Start(path, width, height, fps, error)) return nullptr;
  return recorder;
}

}  // namespace raccoon
