#pragma once
// Rasterizes the app on the GPU through Metal, without a window: the engine
// draws into textures here.
//
// Two ways out. By default each presented frame is copied back as RGBA rows,
// top row first, and handed to the frame path, so clients see no difference
// from the software renderer. With a pool enabled, the engine draws straight
// into a ring of textures backed by IOSurfaces, and a frame is just the
// index of the buffer it is in; a client that looks the surfaces up by ID
// gets the frame without a copy.
//
// A frame leaves once the GPU has drawn it, from the command queue's
// completion handler, so the raster thread never waits. A buffer comes back
// without a fence, once the host has bound the next one: no fence crosses
// processes here without a Mach port, and IOSurfaceIsInUse says only
// whether a pixel buffer wraps the surface, not whether a GPU reads it.
// The ring goes round, so a buffer just given back is drawn into last.
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

#include "gpu_renderer.h"

namespace raccoon {

class MetalRenderer : public GpuRenderer {
 public:
  MetalRenderer();
  ~MetalRenderer() override;

  bool Init(std::string* error);
  void Shutdown() override;

  // id<MTLDevice> and id<MTLCommandQueue>, for FlutterMetalRendererConfig.
  const void* device() const;
  const void* command_queue() const;

  // The engine's callbacks, on its raster thread. A texture for a frame of
  // this size: with a pool, a free pool buffer when there is one, else the
  // readback texture. |texture_id| names it to Present. False when there is
  // none.
  bool NextDrawable(size_t width, size_t height, int64_t* texture_id,
                    const void** texture);
  // Hands the drawn frame on: to the GPU frame callback once the GPU is done
  // with a pool buffer, else read back through |callback|.
  bool Present(int64_t texture_id, const FrameCallback& callback);

  const std::string& description() const override;
  bool EnablePool(size_t count, std::string* error) override;
  void DisablePool() override;
  void SetGpuFrameCallback(GpuFrameCallback callback) override;
  bool pool_set(GpuBufferSet* out) const override;
  bool HasFreeBuffer() const override;
  void Release(uint32_t generation, int index, int fence_fd) override;
  void ReleaseAll() override;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace raccoon
