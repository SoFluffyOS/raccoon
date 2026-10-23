// Writes the camera tests' video: 160x120 H.264 in MP4, 30 fps, a third of a
// second, so a test outlasts it and the camera plays it again; the
// same four quadrants in every frame (red, green; blue, yellow), so a frame
// read upside down or mirrored shows. Media Foundation's sink writer, the
// counterpart of what the runner reads videos with.
//
//   raccoon_test_video OUT.mp4
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

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: raccoon_test_video OUT.mp4\n");
    return 2;
  }
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (!Check(MFStartup(MF_VERSION), "MFStartup")) return 1;
  int code = 1;
  {
    ComPtr<IMFSinkWriter> writer;
    ComPtr<IMFMediaType> output;
    ComPtr<IMFMediaType> input;
    DWORD stream = 0;
    if (!Check(MFCreateSinkWriterFromURL(argv[1], nullptr, nullptr, &writer), "the writer") ||
        !Check(MFCreateMediaType(&output), "the output type") ||
        !Check(MFCreateMediaType(&input), "the input type")) {
      MFShutdown();
      return 1;
    }
    SetVideoType(output.Get(), MFVideoFormat_H264);
    output->SetUINT32(MF_MT_AVG_BITRATE, 2000000);
    SetVideoType(input.Get(), MFVideoFormat_RGB32);
    // Top-down rows.
    input->SetUINT32(MF_MT_DEFAULT_STRIDE, kWidth * 4);
    if (Check(writer->AddStream(output.Get(), &stream), "AddStream") &&
        Check(writer->SetInputMediaType(stream, input.Get(), nullptr), "SetInputMediaType") &&
        Check(writer->BeginWriting(), "BeginWriting")) {
      code = 0;
      for (int i = 0; i < kFrames && code == 0; ++i) {
        ComPtr<IMFMediaBuffer> buffer;
        ComPtr<IMFSample> sample;
        BYTE* data = nullptr;
        const DWORD length = kWidth * kHeight * 4;
        if (!Check(MFCreateMemoryBuffer(length, &buffer), "a buffer") ||
            !Check(buffer->Lock(&data, nullptr, nullptr), "Lock")) {
          code = 1;
          break;
        }
        Fill(data);
        buffer->Unlock();
        buffer->SetCurrentLength(length);
        MFCreateSample(&sample);
        sample->AddBuffer(buffer.Get());
        sample->SetSampleTime(i * kFrameTime);
        sample->SetSampleDuration(kFrameTime);
        if (!Check(writer->WriteSample(stream, sample.Get()), "WriteSample")) code = 1;
      }
      if (code == 0 && !Check(writer->Finalize(), "Finalize")) code = 1;
    }
  }
  MFShutdown();
  CoUninitialize();
  return code;
}
