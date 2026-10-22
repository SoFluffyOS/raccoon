#include "metal_renderer.h"

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include <unistd.h>

#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <vector>

namespace raccoon {
namespace {

const bool kTrace = std::getenv("RACCOON_TRACE") != nullptr;

// Every buffer's IOSurface pixel format: what Metal draws as BGRA8Unorm and
// a host wraps as a 32BGRA pixel buffer.
constexpr uint32_t kFourccBgra = 0x42475241;  // 'BGRA'

// Readback goes into one texture, named 0 to the engine; pool buffer i is
// named i + 1.
constexpr int64_t kReadbackTexture = 0;

IOSurfaceRef CreateSurface(size_t width, size_t height, bool global) {
  NSMutableDictionary* properties = [@{
    (id)kIOSurfaceWidth : @(width),
    (id)kIOSurfaceHeight : @(height),
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfacePixelFormat : @(kFourccBgra),
  } mutableCopy];
  if (global) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // Global: any process looks the surface up by its ID. For a host that
    // does not take surfaces by Mach port; deprecated since 10.11, honoured
    // still, and readable by any process that guesses the ID.
    properties[(id)kIOSurfaceIsGlobal] = @YES;
#pragma clang diagnostic pop
  }
  return IOSurfaceCreate((__bridge CFDictionaryRef)properties);
}

}  // namespace

struct MetalRenderer::Impl {
  struct Buffer {
    IOSurfaceRef surface = nullptr;
    id<MTLTexture> texture = nil;
    uint32_t id = 0;
    uint32_t stride = 0;
    bool busy = false;
  };

  id<MTLDevice> device = nil;
  id<MTLCommandQueue> queue = nil;
  std::string description;

  // The readback target, and the buffer it is copied into for the CPU.
  id<MTLTexture> readback_texture = nil;
  id<MTLBuffer> readback_buffer = nil;
  size_t readback_width = 0;
  size_t readback_height = 0;
  std::vector<uint8_t> frame;

  mutable std::mutex mutex;
  // Global surfaces until the host takes them by Mach port (ShareByPort);
  // then the next ring is built without, at once.
  bool global_surfaces = true;
  bool rebuild = false;
  bool pool_wanted = false;
  size_t pool_count = 0;
  std::vector<Buffer> pool;
  size_t pool_width = 0;
  size_t pool_height = 0;
  uint32_t generation = 0;
  // The pool buffer being drawn, -1 for the readback texture.
  int current = -1;
  // Where the search for a free buffer starts: after the one drawn last, so
  // the ring goes round and a buffer just given back is drawn into last.
  size_t next = 0;
  GpuFrameCallback gpu_frame;
  // Frames whose completion handler has not run yet; Shutdown waits for
  // them, so none runs against a renderer that is gone.
  bool stopping = false;
  size_t in_flight = 0;
  std::condition_variable drained;

  // Mutex held.
  bool EnsureReadback(size_t width, size_t height);
  bool BuildPool(size_t width, size_t height);
  void DestroyPool();
};

bool MetalRenderer::Impl::EnsureReadback(size_t width, size_t height) {
  if (readback_texture != nil && readback_width == width &&
      readback_height == height) {
    return true;
  }
  MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:width
                                  height:height
                               mipmapped:NO];
  descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  descriptor.storageMode = MTLStorageModePrivate;
  readback_texture = [device newTextureWithDescriptor:descriptor];
  readback_buffer = [device newBufferWithLength:width * height * 4
                                        options:MTLResourceStorageModeShared];
  if (readback_texture == nil || readback_buffer == nil) {
    readback_texture = nil;
    readback_buffer = nil;
    return false;
  }
  readback_width = width;
  readback_height = height;
  frame.resize(width * height * 4);
  return true;
}

void MetalRenderer::Impl::DestroyPool() {
  for (Buffer& buffer : pool) {
    buffer.texture = nil;
    if (buffer.surface != nullptr) CFRelease(buffer.surface);
    buffer.surface = nullptr;
  }
  pool.clear();
  pool_width = pool_height = 0;
}

bool MetalRenderer::Impl::BuildPool(size_t width, size_t height) {
  DestroyPool();
  std::vector<Buffer> buffers;
  for (size_t i = 0; i < pool_count; ++i) {
    Buffer buffer;
    buffer.surface = CreateSurface(width, height, global_surfaces);
    if (buffer.surface == nullptr) break;
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:width
                                    height:height
                                 mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    // A surface-backed texture is shared with unified memory, managed with
    // a discrete GPU.
    descriptor.storageMode = device.hasUnifiedMemory ? MTLStorageModeShared
                                                     : MTLStorageModeManaged;
    buffer.texture = [device newTextureWithDescriptor:descriptor
                                            iosurface:buffer.surface
                                                plane:0];
    if (buffer.texture == nil) {
      CFRelease(buffer.surface);
      break;
    }
    buffer.id = IOSurfaceGetID(buffer.surface);
    buffer.stride = static_cast<uint32_t>(IOSurfaceGetBytesPerRow(buffer.surface));
    buffers.push_back(buffer);
  }
  pool = std::move(buffers);
  if (pool.size() != pool_count) {
    DestroyPool();
    return false;
  }
  pool_width = width;
  pool_height = height;
  ++generation;
  if (kTrace) {
    std::fprintf(stderr, "raccoon_runner: metal pool %zu x %zux%zu generation %u\n",
                 pool.size(), width, height, generation);
  }
  return true;
}

MetalRenderer::MetalRenderer() : impl_(std::make_unique<Impl>()) {}

MetalRenderer::~MetalRenderer() { Shutdown(); }

bool MetalRenderer::Init(std::string* error) {
  Impl& m = *impl_;
  m.device = MTLCreateSystemDefaultDevice();
  if (m.device == nil) {
    *error = "no Metal device";
    return false;
  }
  m.queue = [m.device newCommandQueue];
  if (m.queue == nil) {
    *error = "no Metal command queue";
    return false;
  }
  m.description = std::string([m.device.name UTF8String]) +
                  ", Metal, exports IOSurfaces";
  return true;
}

void MetalRenderer::Shutdown() {
  Impl& m = *impl_;
  if (m.device == nil) return;
  {
    std::unique_lock<std::mutex> lock(m.mutex);
    m.stopping = true;
    m.drained.wait(lock, [&m] { return m.in_flight == 0; });
    m.DestroyPool();
  }
  m.readback_texture = nil;
  m.readback_buffer = nil;
  m.queue = nil;
  m.device = nil;
}

const void* MetalRenderer::device() const {
  return (__bridge const void*)impl_->device;
}

const void* MetalRenderer::command_queue() const {
  return (__bridge const void*)impl_->queue;
}

const std::string& MetalRenderer::description() const {
  return impl_->description;
}

bool MetalRenderer::EnablePool(size_t count, std::string* error) {
  Impl& m = *impl_;
  std::lock_guard<std::mutex> lock(m.mutex);
  if (m.device == nil) {
    *error = "no Metal device";
    return false;
  }
  m.pool_wanted = true;
  m.pool_count = count;
  return true;
}

void MetalRenderer::ShareByPort() {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  if (!impl_->global_surfaces) return;
  impl_->global_surfaces = false;
  impl_->rebuild = !impl_->pool.empty();
}

bool MetalRenderer::SurfacePorts(uint32_t generation, std::vector<uint32_t>* ports) const {
  const Impl& m = *impl_;
  std::lock_guard<std::mutex> lock(m.mutex);
  if (m.pool.empty() || generation != m.generation) return false;
  ports->clear();
  for (const Impl::Buffer& buffer : m.pool) {
    // A send right of the caller's to own and pass on.
    ports->push_back(IOSurfaceCreateMachPort(buffer.surface));
  }
  return true;
}

void MetalRenderer::DisablePool() {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  impl_->pool_wanted = false;
}

void MetalRenderer::SetGpuFrameCallback(GpuFrameCallback callback) {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  impl_->gpu_frame = std::move(callback);
}

bool MetalRenderer::pool_set(GpuBufferSet* out) const {
  const Impl& m = *impl_;
  std::lock_guard<std::mutex> lock(m.mutex);
  if (m.pool.empty()) return false;
  out->generation = m.generation;
  out->width = m.pool_width;
  out->height = m.pool_height;
  out->fourcc = kFourccBgra;
  out->modifier = 0;
  out->strides.clear();
  out->offsets.clear();
  out->fds.clear();
  out->surface_ids.clear();
  for (const Impl::Buffer& buffer : m.pool) {
    out->strides.push_back(buffer.stride);
    out->offsets.push_back(0);
    out->surface_ids.push_back(buffer.id);
  }
  return true;
}

bool MetalRenderer::HasFreeBuffer() const {
  const Impl& m = *impl_;
  std::lock_guard<std::mutex> lock(m.mutex);
  if (!m.pool_wanted || m.pool.empty()) return true;
  for (const Impl::Buffer& buffer : m.pool) {
    if (!buffer.busy) return true;
  }
  return false;
}

void MetalRenderer::Release(uint32_t generation, int index, int fence_fd) {
  // No fence crosses the socket on this host; one that did is let go.
  if (fence_fd >= 0) close(fence_fd);
  Impl& m = *impl_;
  std::lock_guard<std::mutex> lock(m.mutex);
  if (generation != m.generation || index < 0 ||
      static_cast<size_t>(index) >= m.pool.size()) {
    return;
  }
  m.pool[index].busy = false;
  if (kTrace) std::fprintf(stderr, "raccoon_runner: metal release pool %d\n", index);
}

void MetalRenderer::ReleaseAll() {
  Impl& m = *impl_;
  std::lock_guard<std::mutex> lock(m.mutex);
  for (size_t i = 0; i < m.pool.size(); ++i) {
    // The one being drawn stays taken until it is presented.
    if (static_cast<int>(i) == m.current) continue;
    m.pool[i].busy = false;
  }
  if (kTrace) std::fprintf(stderr, "raccoon_runner: metal release pool all\n");
}

bool MetalRenderer::NextDrawable(size_t width, size_t height, int64_t* texture_id,
                                 const void** texture) {
  if (width == 0 || height == 0) return false;
  Impl& m = *impl_;
  std::lock_guard<std::mutex> lock(m.mutex);
  m.current = -1;
  if (!m.pool_wanted && !m.pool.empty()) m.DestroyPool();
  if (m.pool_wanted) {
    if (m.pool.empty() || m.pool_width != width || m.pool_height != height || m.rebuild) {
      m.rebuild = false;
      if (!m.BuildPool(width, height)) {
        m.pool_wanted = false;
        std::fprintf(stderr,
                     "raccoon_runner: no GPU buffers: the pool could not be "
                     "built; frames by readback\n");
      }
    }
    for (size_t n = 0; n < m.pool.size(); ++n) {
      const size_t i = (m.next + n) % m.pool.size();
      Impl::Buffer& buffer = m.pool[i];
      if (buffer.busy) continue;
      buffer.busy = true;
      m.current = static_cast<int>(i);
      m.next = i + 1;
      *texture_id = static_cast<int64_t>(i) + 1;
      *texture = (__bridge const void*)buffer.texture;
      if (kTrace) std::fprintf(stderr, "raccoon_runner: metal texture -> pool %zu\n", i);
      return true;
    }
    // Every buffer is with the client: this frame goes by readback.
    if (kTrace) std::fprintf(stderr, "raccoon_runner: metal texture -> readback\n");
  }
  if (!m.EnsureReadback(width, height)) return false;
  *texture_id = kReadbackTexture;
  *texture = (__bridge const void*)m.readback_texture;
  return true;
}

bool MetalRenderer::Present(int64_t texture_id, const FrameCallback& callback) {
  Impl& m = *impl_;
  if (texture_id != kReadbackTexture) {
    uint32_t generation = 0;
    int index = -1;
    size_t width = 0;
    size_t height = 0;
    {
      std::lock_guard<std::mutex> lock(m.mutex);
      index = m.current;
      generation = m.generation;
      width = m.pool_width;
      height = m.pool_height;
      m.current = -1;
      if (index < 0 || m.stopping) return false;
      ++m.in_flight;
    }
    // The engine submitted its drawing on this queue; a command buffer after
    // it completes once that is done, and only then does the frame leave.
    Impl* impl = impl_.get();
    id<MTLCommandBuffer> commands = [m.queue commandBuffer];
    [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
      GpuFrameCallback frame;
      {
        std::lock_guard<std::mutex> lock(impl->mutex);
        if (!impl->stopping) frame = impl->gpu_frame;
      }
      if (kTrace) std::fprintf(stderr, "raccoon_runner: metal present pool %d\n", index);
      if (frame) frame(generation, index, width, height, -1);
      {
        std::lock_guard<std::mutex> lock(impl->mutex);
        --impl->in_flight;
      }
      impl->drained.notify_all();
    }];
    [commands commit];
    return true;
  }
  if (m.readback_texture == nil) return false;
  // Pixels to the CPU: a blit into the shared buffer, waited for here.
  const size_t width = m.readback_width;
  const size_t height = m.readback_height;
  const size_t row_bytes = width * 4;
  id<MTLCommandBuffer> commands = [m.queue commandBuffer];
  id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
  [blit copyFromTexture:m.readback_texture
             sourceSlice:0
             sourceLevel:0
            sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:MTLSizeMake(width, height, 1)
                toBuffer:m.readback_buffer
       destinationOffset:0
  destinationBytesPerRow:row_bytes
destinationBytesPerImage:row_bytes * height];
  [blit endEncoding];
  [commands commit];
  [commands waitUntilCompleted];
  // Metal drew BGRA, top row first; the frame path on this host wants RGBA.
  const uint8_t* source = static_cast<const uint8_t*>(m.readback_buffer.contents);
  uint8_t* target = m.frame.data();
  for (size_t i = 0; i < width * height; ++i) {
    target[i * 4 + 0] = source[i * 4 + 2];
    target[i * 4 + 1] = source[i * 4 + 1];
    target[i * 4 + 2] = source[i * 4 + 0];
    target[i * 4 + 3] = source[i * 4 + 3];
  }
  callback(m.frame.data(), row_bytes, height);
  return true;
}

}  // namespace raccoon
