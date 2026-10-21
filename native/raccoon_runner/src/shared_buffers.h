#pragma once

#include <cstddef>
#include <mutex>
#include <string>
#include <vector>

namespace raccoon {

// Same-sized memory buffers the client maps too. The raster thread acquires a
// free one per frame; the client gives it back with ReleaseBuffer.
class SharedBufferPool {
 public:
  SharedBufferPool() = default;
  ~SharedBufferPool();
  SharedBufferPool(const SharedBufferPool&) = delete;
  SharedBufferPool& operator=(const SharedBufferPool&) = delete;

  bool Allocate(size_t count, size_t size, std::string* error);

  size_t count() const { return buffers_.size(); }
  size_t size() const { return size_; }
  std::vector<int> fds() const;

  // A free buffer's index, marked busy, or -1 when all are in use.
  int AcquireFree();
  void* Data(int index) { return buffers_[index].data; }
  void Release(int index);
  void ReleaseAll();

 private:
  struct Buffer {
    int fd = -1;
    void* data = nullptr;
    bool busy = false;
  };

  std::vector<Buffer> buffers_;
  size_t size_ = 0;
  std::mutex mutex_;
};

}  // namespace raccoon
