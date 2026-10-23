// A video as the camera's source on Windows: Media Foundation's source
// reader decodes it to BGRA, a frame at a time as it comes due, and starts
// it again at its end.
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>
#include <filesystem>

#include "camera_source.h"

namespace raccoon {

namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kVideo = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

std::string Hresult(const char* what, HRESULT result) {
  char text[64];
  std::snprintf(text, sizeof(text), " (0x%08lx)", static_cast<unsigned long>(result));
  return what + std::string(text);
}

class VideoSource : public LoopingVideo {
 public:
  ~VideoSource() override {
    reader_.Reset();
    if (started_) MFShutdown();
    if (com_) CoUninitialize();
  }

  bool Open(const std::string& path, std::string* error) {
    // The loop thread may already be in an apartment; either kind serves.
    com_ = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET))) {
      *error = "Media Foundation is not available";
      return false;
    }
    started_ = true;
    ComPtr<IMFAttributes> attributes;
    MFCreateAttributes(&attributes, 1);
    // The reader's own converter, from whatever the decoder gives to BGRA.
    attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    const std::wstring wide = std::filesystem::u8path(path).wstring();
    HRESULT result = MFCreateSourceReaderFromURL(wide.c_str(), attributes.Get(), &reader_);
    if (FAILED(result)) {
      *error = Hresult("not a video Media Foundation can open", result);
      return false;
    }
    reader_->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
    reader_->SetStreamSelection(kVideo, TRUE);
    ComPtr<IMFMediaType> wanted;
    MFCreateMediaType(&wanted);
    wanted->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    wanted->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    result = reader_->SetCurrentMediaType(kVideo, nullptr, wanted.Get());
    if (FAILED(result)) {
      *error = Hresult("no video stream it can decode", result);
      return false;
    }
    ComPtr<IMFMediaType> current;
    reader_->GetCurrentMediaType(kVideo, &current);
    UINT32 width = 0;
    UINT32 height = 0;
    MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &width, &height);
    width_ = width;
    height_ = height;
    // Top-down unless the type says its rows run bottom-up.
    UINT32 stride = 0;
    if (SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride))) {
      bottom_up_ = static_cast<INT32>(stride) < 0;
    }
    PROPVARIANT duration;
    PropVariantInit(&duration);
    if (SUCCEEDED(reader_->GetPresentationAttribute(
            static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION, &duration))) {
      duration_micros_ = static_cast<int64_t>(duration.uhVal.QuadPart) / 10;
    }
    PropVariantClear(&duration);
    if (width_ == 0 || height_ == 0 || !Begin()) {
      *error = "no frame in it";
      return false;
    }
    return true;
  }

 private:
  void Restart() override {
    PROPVARIANT start;
    PropVariantInit(&start);
    start.vt = VT_I8;
    start.hVal.QuadPart = 0;
    reader_->SetCurrentPosition(GUID_NULL, start);
    PropVariantClear(&start);
  }

  bool ReadNext(CameraPicture* frame, int64_t* time_micros) override {
    for (;;) {
      DWORD flags = 0;
      LONGLONG timestamp = 0;
      ComPtr<IMFSample> sample;
      if (FAILED(reader_->ReadSample(kVideo, 0, nullptr, &flags, &timestamp, &sample))) {
        return false;
      }
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) return false;
      // A gap or a format change comes without a sample; read on.
      if (!sample) continue;
      ComPtr<IMFMediaBuffer> buffer;
      if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) return false;
      BYTE* data = nullptr;
      DWORD length = 0;
      if (FAILED(buffer->Lock(&data, nullptr, &length))) return false;
      const size_t row = width_ * 4;
      if (length < row * height_) {
        buffer->Unlock();
        return false;
      }
      frame->width = width_;
      frame->height = height_;
      frame->bgra.resize(row * height_);
      for (size_t y = 0; y < height_; ++y) {
        const size_t from = bottom_up_ ? height_ - 1 - y : y;
        std::memcpy(frame->bgra.data() + y * row, data + from * row, row);
      }
      buffer->Unlock();
      // RGB32 leaves the fourth byte undefined.
      for (size_t i = 3; i < frame->bgra.size(); i += 4) frame->bgra[i] = 255;
      // Media Foundation counts in 100 ns.
      *time_micros = timestamp / 10;
      return true;
    }
  }

  bool com_ = false;
  bool started_ = false;
  ComPtr<IMFSourceReader> reader_;
  size_t width_ = 0;
  size_t height_ = 0;
  bool bottom_up_ = false;
};

}  // namespace

std::unique_ptr<CameraSource> OpenCameraVideo(const std::string& path, std::string* error) {
  auto video = std::make_unique<VideoSource>();
  if (!video->Open(path, error)) return nullptr;
  return video;
}

}  // namespace raccoon
