#include "software_frame.h"

#include <cstdio>
#include <cstring>
#if defined(_WIN32)
#include <io.h>
#else
#include <unistd.h>
#endif

namespace raccoon {

namespace {

// How long a frame waits for a shared buffer before it goes inline: as long
// as a GPU frame waits for the ring.
constexpr auto kInlineHold = std::chrono::milliseconds(100);

}  // namespace

void SoftwareFrame::Present(const void* allocation, size_t row_bytes,
                            size_t height) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    row_bytes_ = row_bytes;
    width_ = row_bytes / 4;
    height_ = height;
    ++frame_count_;
    const size_t bytes = row_bytes * height;
    int index = -1;
    if (pool_ != nullptr && bytes <= pool_->size()) {
      index = pool_->AcquireFree();
      // A frame nobody sent yet is superseded: with every other buffer at
      // the client, this one takes its buffer rather than going inline.
      if (index < 0 && pending_shared_.index >= 0) {
        index = pending_shared_.index;
        pending_shared_ = Shared{};
      }
    }
    if (index >= 0) {
      // A frame nobody sent yet is superseded; free its buffer.
      if (pending_shared_.index >= 0) pool_->Release(pending_shared_.index);
      std::memcpy(pool_->Data(index), allocation, bytes);
      pending_shared_ = {index, width_, height_, row_bytes_, frame_count_};
      inline_waits_ = false;
    } else {
      // No pool, a frame too big for it, or every buffer still with the
      // client: send this frame inline rather than lose it. A shared frame
      // not yet sent is older than this one; free its buffer.
      if (pool_ != nullptr && pending_shared_.index >= 0) {
        pool_->Release(pending_shared_.index);
        pending_shared_ = Shared{};
      }
      pixels_.resize(bytes);
      std::memcpy(pixels_.data(), allocation, bytes);
      inline_sequence_ = frame_count_;
      inline_waits_ = pool_ != nullptr && bytes <= pool_->size();
      inline_at_ = std::chrono::steady_clock::now();
    }
  }
  if (presented_) presented_();
}

void SoftwareFrame::SetSharedPool(SharedBufferPool* pool) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (pool_ != nullptr && pending_shared_.index >= 0) {
    // Keep a frame that was not sent yet: it goes out inline instead.
    const size_t bytes = pending_shared_.row_bytes * pending_shared_.height;
    pixels_.resize(bytes);
    std::memcpy(pixels_.data(), pool_->Data(pending_shared_.index), bytes);
    inline_sequence_ = pending_shared_.sequence;
    pool_->Release(pending_shared_.index);
  }
  pending_shared_ = Shared{};
  inline_waits_ = false;
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

bool SoftwareFrame::CopyLatest(Copy* out, size_t after_sequence) {
  std::lock_guard<std::mutex> lock(mutex_);
  // Only the frame these pixels belong to, and only while it is the latest:
  // pixels_ is not updated for frames that went into shared buffers.
  if (inline_sequence_ == 0 || inline_sequence_ != frame_count_ ||
      inline_sequence_ <= after_sequence) {
    return false;
  }
  if (inline_waits_ && std::chrono::steady_clock::now() - inline_at_ < kInlineHold) {
    return false;
  }
  inline_waits_ = false;
  out->pixels.assign(reinterpret_cast<const char*>(pixels_.data()), pixels_.size());
  out->width = width_;
  out->height = height_;
  out->row_bytes = row_bytes_;
  out->sequence = frame_count_;
  return true;
}

bool SoftwareFrame::PromoteInline() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!inline_waits_ || inline_sequence_ != frame_count_ || pool_ == nullptr ||
      pixels_.size() > pool_->size()) {
    return false;
  }
  const int index = pool_->AcquireFree();
  if (index < 0) return false;
  std::memcpy(pool_->Data(index), pixels_.data(), pixels_.size());
  pending_shared_ = {index, width_, height_, row_bytes_, inline_sequence_};
  inline_sequence_ = 0;
  inline_waits_ = false;
  return true;
}

int SoftwareFrame::MillisUntilInline() const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!inline_waits_ || inline_sequence_ != frame_count_) return -1;
  const auto left = kInlineHold - (std::chrono::steady_clock::now() - inline_at_);
  if (left <= std::chrono::milliseconds(0)) return 0;
  return static_cast<int>(std::chrono::ceil<std::chrono::milliseconds>(left).count());
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


SoftwareFrame::~SoftwareFrame() {
#if !defined(_WIN32)
  if (pending_gpu_.fence_fd >= 0) close(pending_gpu_.fence_fd);
#endif
}

void SoftwareFrame::PresentGpu(uint32_t generation, int index, size_t width,
                               size_t height, int fence_fd) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    width_ = width;
    height_ = height;
    row_bytes_ = width * 4;
    ++frame_count_;
    if (pending_gpu_.index >= 0) {
      if (release_gpu_) release_gpu_(pending_gpu_.generation, pending_gpu_.index);
      if (pending_gpu_.fence_fd >= 0) close(pending_gpu_.fence_fd);
    }
    pending_gpu_ = {generation, index, width, height, frame_count_, fence_fd};
  }
  if (presented_) presented_();
}

bool SoftwareFrame::TakeGpu(Gpu* out) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (pending_gpu_.index < 0) return false;
  *out = pending_gpu_;
  pending_gpu_ = Gpu{};
  return true;
}

}  // namespace raccoon
