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
    ++frame_count_;
    const size_t bytes = row_bytes * height;
    if (pool_ != nullptr && bytes <= pool_->size()) {
      const int index = pool_->AcquireFree();
      if (index >= 0) {
        // A frame nobody sent yet is superseded; free its buffer.
        if (pending_shared_.index >= 0) pool_->Release(pending_shared_.index);
        std::memcpy(pool_->Data(index), allocation, bytes);
        pending_shared_ = {index, width_, height_, row_bytes_, frame_count_};
      }
      // No free buffer: the client is behind, this frame is dropped.
    } else {
      pixels_.resize(bytes);
      std::memcpy(pixels_.data(), allocation, bytes);
    }
  }
  if (presented_) presented_();
}

void SoftwareFrame::SetSharedPool(SharedBufferPool* pool) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (pool_ != nullptr && pending_shared_.index >= 0) {
    pool_->Release(pending_shared_.index);
  }
  pending_shared_ = Shared{};
  pool_ = pool;
}

bool SoftwareFrame::TakeShared(Shared* out) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (pending_shared_.index < 0) return false;
  *out = pending_shared_;
  pending_shared_ = Shared{};
  return true;
}

size_t SoftwareFrame::LatestSizeBytes() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return row_bytes_ * height_;
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
