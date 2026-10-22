#include "shared_buffers.h"

#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

#include <cerrno>
#include <cstdlib>
#include <cstring>

namespace raccoon {

#if defined(_WIN32)

// A buffer's handle would have to be duplicated into the client, and a
// Windows socket carries no handles, nor can Dart take one; frames ride
// inline there.
SharedBufferPool::~SharedBufferPool() = default;

bool SharedBufferPool::Allocate(size_t, size_t, std::string* error) {
  *error = "no shared buffers on Windows";
  return false;
}

#else

namespace {

// Linux backs a buffer with an anonymous memfd. macOS has no memfd, and its
// POSIX shared memory objects refuse read(), which is how the client takes
// the pixels out of a buffer; an unlinked file in the temporary directory can
// be mapped here and read there, through the same page cache.
int OpenBufferFile(std::string* error) {
#if defined(__linux__)
  const int fd = memfd_create("raccoon-frame", MFD_CLOEXEC);
  if (fd < 0) *error = std::string("memfd_create: ") + std::strerror(errno);
  return fd;
#else
  const char* temp = std::getenv("TMPDIR");
  std::string path = temp == nullptr || *temp == '\0' ? "/tmp" : temp;
  if (path.back() != '/') path += '/';
  path += "raccoon-frame-XXXXXX";
  std::vector<char> name(path.begin(), path.end());
  name.push_back('\0');
  const int fd = mkstemp(name.data());
  if (fd < 0) {
    *error = std::string("mkstemp: ") + std::strerror(errno);
    return fd;
  }
  unlink(name.data());
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  return fd;
#endif
}

}  // namespace

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
    buffer.fd = OpenBufferFile(error);
    if (buffer.fd < 0) return false;
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

#endif

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
