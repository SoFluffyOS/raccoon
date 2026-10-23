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

class VideoSource : public CameraSource {
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
      duration_ = static_cast<int64_t>(duration.uhVal.QuadPart);
    }
    PropVariantClear(&duration);
    if (width_ == 0 || height_ == 0 || !ReadNext(&current_, &current_time_)) {
      *error = "no frame in it";
      return false;
    }
    has_next_ = ReadNext(&next_, &next_time_);
    return true;
  }

  const CameraPicture* FrameAt(uint64_t time_micros, uint64_t* number) override {
    if (!opened_at_set_) {
      opened_at_ = time_micros;
      opened_at_set_ = true;
    }
    // In Media Foundation's 100 ns units, within one pass of the video.
    int64_t position = static_cast<int64_t>(time_micros - opened_at_) * 10;
    if (duration_ > 0) position %= duration_;
    if (position < last_position_) Rewind();
    last_position_ = position;
    while (has_next_ && next_time_ <= position) {
      std::swap(current_, next_);
      current_time_ = next_time_;
      ++frame_number_;
      has_next_ = ReadNext(&next_, &next_time_);
    }
    *number = frame_number_;
    return &current_;
  }

 private:
  // Back to the start, for the next pass.
  void Rewind() {
    PROPVARIANT start;
    PropVariantInit(&start);
    start.vt = VT_I8;
    start.hVal.QuadPart = 0;
    reader_->SetCurrentPosition(GUID_NULL, start);
    PropVariantClear(&start);
    if (ReadNext(&current_, &current_time_)) ++frame_number_;
    has_next_ = ReadNext(&next_, &next_time_);
  }

  // The next decoded frame and its time; false at the end or on an error.
  bool ReadNext(CameraPicture* frame, int64_t* time) {
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
      *time = timestamp;
      return true;
    }
  }

  bool com_ = false;
  bool started_ = false;
  ComPtr<IMFSourceReader> reader_;
  size_t width_ = 0;
  size_t height_ = 0;
  bool bottom_up_ = false;
  int64_t duration_ = 0;
  CameraPicture current_;
  int64_t current_time_ = 0;
  CameraPicture next_;
  int64_t next_time_ = 0;
  bool has_next_ = false;
  uint64_t frame_number_ = 1;
  uint64_t opened_at_ = 0;
  bool opened_at_set_ = false;
  int64_t last_position_ = 0;
};

}  // namespace

std::unique_ptr<CameraSource> OpenCameraVideo(const std::string& path, std::string* error) {
  auto video = std::make_unique<VideoSource>();
  if (!video->Open(path, error)) return nullptr;
  return video;
}

}  // namespace raccoon
