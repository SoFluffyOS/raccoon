// Writes the camera tests' video: 160x120 H.264 in MP4, 30 fps, a third of a
// second, so a test outlasts it and the camera plays it again; the
// same four quadrants in every frame (red, green; blue, yellow), so a frame
// read upside down or mirrored shows. Media Foundation's sink writer, the
// counterpart of what the runner reads videos with.
//
//   raccoon_test_video OUT.mp4
//   raccoon_test_video --probe VIDEO   what a video holds, see ProbeVideo
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>
#include <string>

using Microsoft::WRL::ComPtr;

namespace {

constexpr UINT32 kWidth = 160;
constexpr UINT32 kHeight = 120;
constexpr UINT32 kFps = 30;
constexpr int kFrames = 10;
constexpr LONGLONG kFrameTime = 10000000 / kFps;

void SetVideoType(IMFMediaType* type, const GUID& subtype) {
  type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  type->SetGUID(MF_MT_SUBTYPE, subtype);
  type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  MFSetAttributeSize(type, MF_MT_FRAME_SIZE, kWidth, kHeight);
  MFSetAttributeRatio(type, MF_MT_FRAME_RATE, kFps, 1);
  MFSetAttributeRatio(type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
}

// The quadrant colours, as B, G, R.
void Fill(BYTE* pixels) {
  for (UINT32 y = 0; y < kHeight; ++y) {
    for (UINT32 x = 0; x < kWidth; ++x) {
      BYTE* p = pixels + (y * kWidth + x) * 4;
      const bool right = x >= kWidth / 2;
      const bool bottom = y >= kHeight / 2;
      BYTE r = 0, g = 0, b = 0;
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

bool Check(HRESULT result, const char* what) {
  if (SUCCEEDED(result)) return true;
  std::fprintf(stderr, "raccoon_test_video: %s failed (0x%08lx)\n", what,
               static_cast<unsigned long>(result));
  return false;
}

// Writes the test video to |path|.
int WriteVideo(const wchar_t* path) {
  ComPtr<IMFSinkWriter> writer;
  ComPtr<IMFMediaType> output;
  ComPtr<IMFMediaType> input;
  DWORD stream = 0;
  if (!Check(MFCreateSinkWriterFromURL(path, nullptr, nullptr, &writer), "the writer") ||
      !Check(MFCreateMediaType(&output), "the output type") ||
      !Check(MFCreateMediaType(&input), "the input type")) {
    return 1;
  }
  SetVideoType(output.Get(), MFVideoFormat_H264);
  output->SetUINT32(MF_MT_AVG_BITRATE, 2000000);
  SetVideoType(input.Get(), MFVideoFormat_RGB32);
  // Top-down rows.
  input->SetUINT32(MF_MT_DEFAULT_STRIDE, kWidth * 4);
  if (!Check(writer->AddStream(output.Get(), &stream), "AddStream") ||
      !Check(writer->SetInputMediaType(stream, input.Get(), nullptr), "SetInputMediaType") ||
      !Check(writer->BeginWriting(), "BeginWriting")) {
    return 1;
  }
  for (int i = 0; i < kFrames; ++i) {
    ComPtr<IMFMediaBuffer> buffer;
    ComPtr<IMFSample> sample;
    BYTE* data = nullptr;
    const DWORD length = kWidth * kHeight * 4;
    if (!Check(MFCreateMemoryBuffer(length, &buffer), "a buffer") ||
        !Check(buffer->Lock(&data, nullptr, nullptr), "Lock")) {
      return 1;
    }
    Fill(data);
    buffer->Unlock();
    buffer->SetCurrentLength(length);
    MFCreateSample(&sample);
    sample->AddBuffer(buffer.Get());
    sample->SetSampleTime(i * kFrameTime);
    sample->SetSampleDuration(kFrameTime);
    if (!Check(writer->WriteSample(stream, sample.Get()), "WriteSample")) return 1;
  }
  return Check(writer->Finalize(), "Finalize") ? 0 : 1;
}

// Prints what the video at |path| holds, for the recording tests: its
// frames, size and duration, and the colours of its first frame a quarter
// down, at a fourteenth of its width from each side:
//   frames=N size=WxH duration_ms=D left=R,G,B right=R,G,B
int ProbeVideo(const wchar_t* path) {
  ComPtr<IMFAttributes> attributes;
  MFCreateAttributes(&attributes, 1);
  attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  ComPtr<IMFSourceReader> reader;
  if (!Check(MFCreateSourceReaderFromURL(path, attributes.Get(), &reader), "the reader")) {
    return 1;
  }
  const DWORD video = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
  ComPtr<IMFMediaType> wanted;
  MFCreateMediaType(&wanted);
  wanted->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  wanted->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (!Check(reader->SetCurrentMediaType(video, nullptr, wanted.Get()), "RGB32")) return 1;
  ComPtr<IMFMediaType> current;
  reader->GetCurrentMediaType(video, &current);
  UINT32 width = 0;
  UINT32 height = 0;
  MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &width, &height);
  UINT32 stride = width * 4;
  current->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride);
  const bool bottom_up = static_cast<INT32>(stride) < 0;
  PROPVARIANT duration;
  PropVariantInit(&duration);
  reader->GetPresentationAttribute(static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE),
                                   MF_PD_DURATION, &duration);
  const unsigned long long duration_ms = duration.uhVal.QuadPart / 10000;
  PropVariantClear(&duration);
  int frames = 0;
  BYTE left[3] = {};
  BYTE right[3] = {};
  for (;;) {
    DWORD flags = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(video, 0, nullptr, &flags, nullptr, &sample))) break;
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    if (!sample) continue;
    if (frames++ > 0) continue;
    ComPtr<IMFMediaBuffer> buffer;
    sample->ConvertToContiguousBuffer(&buffer);
    BYTE* data = nullptr;
    buffer->Lock(&data, nullptr, nullptr);
    const UINT32 row = height / 4;
    const UINT32 at = bottom_up ? height - 1 - row : row;
    const BYTE* l = data + at * width * 4 + (width / 14) * 4;
    const BYTE* r = data + at * width * 4 + (width * 13 / 14) * 4;
    for (int i = 0; i < 3; ++i) {
      left[i] = l[2 - i];
      right[i] = r[2 - i];
    }
    buffer->Unlock();
  }
  std::printf("frames=%d size=%ux%u duration_ms=%llu left=%u,%u,%u right=%u,%u,%u\n", frames,
              width, height, duration_ms, left[0], left[1], left[2], right[0], right[1],
              right[2]);
  return frames > 0 ? 0 : 1;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  const bool probe = argc == 3 && std::wstring(argv[1]) == L"--probe";
  if (argc != 2 && !probe) {
    std::fprintf(stderr, "usage: raccoon_test_video OUT.mp4 | --probe VIDEO\n");
    return 2;
  }
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (!Check(MFStartup(MF_VERSION), "MFStartup")) return 1;
  const int code = probe ? ProbeVideo(argv[2]) : WriteVideo(argv[1]);
  MFShutdown();
  CoUninitialize();
  return code;
}
