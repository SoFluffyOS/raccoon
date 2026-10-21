#include "software_frame.h"

#include <cstdio>
#include <cstring>

namespace raccoon {

void SoftwareFrame::Present(const void* allocation, size_t row_bytes,
                            size_t height) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    row_bytes_ = row_bytes;
    width_ = row_bytes / 4;
    height_ = height;
    pixels_.resize(row_bytes * height);
    std::memcpy(pixels_.data(), allocation, row_bytes * height);
    ++frame_count_;
  }
  if (presented_) presented_();
}

bool SoftwareFrame::CopyLatest(Copy* out, size_t after_sequence) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (frame_count_ == 0 || frame_count_ <= after_sequence) return false;
  out->pixels = pixels_;
  out->width = width_;
  out->height = height_;
  out->row_bytes = row_bytes_;
  out->sequence = frame_count_;
  return true;
}

size_t SoftwareFrame::FrameCount() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return frame_count_;
}

bool SoftwareFrame::WritePpm(const std::string& path, bool bgra) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (pixels_.empty()) return false;
  FILE* file = std::fopen(path.c_str(), "wb");
  if (file == nullptr) return false;
  std::fprintf(file, "P6\n%zu %zu\n255\n", width_, height_);
  std::vector<uint8_t> row(width_ * 3);
  for (size_t y = 0; y < height_; ++y) {
    const uint8_t* src = pixels_.data() + y * row_bytes_;
    for (size_t x = 0; x < width_; ++x) {
      const uint8_t* px = src + x * 4;
      row[x * 3 + 0] = bgra ? px[2] : px[0];
      row[x * 3 + 1] = px[1];
      row[x * 3 + 2] = bgra ? px[0] : px[2];
    }
    std::fwrite(row.data(), 1, row.size(), file);
  }
  std::fclose(file);
  return true;
}

}  // namespace raccoon
