#include "shared_buffers.h"

#include <sys/mman.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>

namespace raccoon {

SharedBufferPool::~SharedBufferPool() {
  for (Buffer& buffer : buffers_) {
    if (buffer.data != nullptr) munmap(buffer.data, size_);
    if (buffer.fd >= 0) close(buffer.fd);
  }
}

bool SharedBufferPool::Allocate(size_t count, size_t size, std::string* error) {
  size_ = size;
  for (size_t i = 0; i < count; ++i) {
    Buffer buffer;
    buffer.fd = memfd_create("raccoon-frame", MFD_CLOEXEC);
    if (buffer.fd < 0) {
      *error = std::string("memfd_create: ") + std::strerror(errno);
      return false;
    }
    if (ftruncate(buffer.fd, static_cast<off_t>(size)) < 0) {
      *error = std::string("ftruncate: ") + std::strerror(errno);
      close(buffer.fd);
      return false;
    }
    buffer.data = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED,
                       buffer.fd, 0);
    if (buffer.data == MAP_FAILED) {
      *error = std::string("mmap: ") + std::strerror(errno);
      close(buffer.fd);
      return false;
    }
    buffers_.push_back(buffer);
  }
  return true;
}

std::vector<int> SharedBufferPool::fds() const {
  std::vector<int> out;
  for (const Buffer& buffer : buffers_) out.push_back(buffer.fd);
  return out;
}

int SharedBufferPool::AcquireFree() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (size_t i = 0; i < buffers_.size(); ++i) {
    if (buffers_[i].busy) continue;
    buffers_[i].busy = true;
    return static_cast<int>(i);
  }
  return -1;
}

void SharedBufferPool::Release(int index) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (index >= 0 && static_cast<size_t>(index) < buffers_.size()) {
    buffers_[index].busy = false;
  }
}

void SharedBufferPool::ReleaseAll() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (Buffer& buffer : buffers_) buffer.busy = false;
}

}  // namespace raccoon
