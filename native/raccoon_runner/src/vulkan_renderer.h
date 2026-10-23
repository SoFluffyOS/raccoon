#pragma once
// Rasterizes the app on the GPU through Vulkan, without a window: Windows'
// prebuilt embedder has no OpenGL of its own and no Metal, but the
// embedder API's Vulkan renderer. vulkan-1.dll, which every GPU driver
// installs, is opened at run time; the engine draws into images made here.
//
// By default each presented frame is read back as BGRA rows, top row first,
// and handed to the frame path, so clients see no difference from the
// software renderer; what moves off the CPU is the rasterization. With a
// pool enabled, the engine draws straight into a ring of D3D11 textures
// made shareable and imported into Vulkan, and a frame is the index of its
// buffer: a client opens the textures by their shared handles, as Flutter's
// Windows texture registrar does, and gets the frame without a copy. The
// engine syncs with the host before it presents, so neither way waits on
// the drawing.
#if RACCOON_HAS_VULKAN
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_WIN32_KHR
#include <vulkan/vulkan.h>
// windows.h, which the Win32 half of vulkan.h brings, renames the
// embedder's GetCurrentTime.
#undef GetCurrentTime

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "gpu_renderer.h"

struct ID3D11Device;
struct ID3D11Texture2D;

namespace raccoon {

class VulkanRenderer : public GpuRenderer {
 public:
  ~VulkanRenderer() override;

  bool Init(std::string* error);
  void Shutdown() override;

  // The engine's callbacks, on its raster thread.
  // An image for a frame of this size, made or resized as needed: a free
  // pool buffer when there is one. Null when it cannot be.
  VkImage NextImage(size_t width, size_t height);
  // Hands the drawn frame on: to the GPU frame callback when it is in a pool
  // buffer, else read back through |callback|.
  bool Present(VkImage image, const FrameCallback& callback);
  // vkGetInstanceProcAddr, with the queue's calls behind the queue's lock.
  void* ProcAddress(VkInstance instance, const char* name) const;

  VkInstance instance() const { return instance_; }
  VkPhysicalDevice physical_device() const { return physical_device_; }
  VkDevice device() const { return device_; }
  VkQueue queue() const { return queue_; }
  uint32_t queue_family() const { return queue_family_; }
  uint32_t api_version() const { return kApiVersion; }
  static constexpr VkFormat kFormat = VK_FORMAT_B8G8R8A8_UNORM;

  // What rasterizes: the device's name.
  const std::string& description() const override { return description_; }

  // The pool is a ring of shared D3D11 textures; false, with why, when the
  // device cannot import them.
  bool EnablePool(size_t count, std::string* error) override;
  void DisablePool() override;
  void SetGpuFrameCallback(GpuFrameCallback callback) override {
    gpu_frame_ = std::move(callback);
  }
  // The set names each buffer by its texture's shared handle, as a 32-bit
  // value: what DXGI hands out and Flutter's texture registrar opens.
  bool pool_set(GpuBufferSet* out) const override;
  bool HasFreeBuffer() const override;
  void Release(uint32_t generation, int index, int fence_fd) override;
  void ReleaseAll() override;

 private:
  static constexpr uint32_t kApiVersion = VK_API_VERSION_1_1;
  // Frames go round two images: one being drawn while the other is read.
  static constexpr size_t kImages = 2;

  struct Image {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
  };

  struct PoolBuffer {
    ID3D11Texture2D* texture = nullptr;
    void* shared_handle = nullptr;
    Image image;
    bool busy = false;
  };

  // The ring for frames of this size, made when the size or count changes.
  // Holding mutex_.
  bool EnsurePool(size_t width, size_t height);
  void DestroyPool();
  // The D3D11 device on this Vulkan device's adapter, made once.
  bool EnsureD3d(std::string* error);
  // Records and runs one barrier on |image|, waiting for it.
  bool Transition(VkImage image, VkImageLayout from, VkImageLayout to, uint32_t to_family);

  // The queue's calls, locked: the engine's and the readback's.
  static VKAPI_ATTR VkResult VKAPI_CALL LockedQueueSubmit(VkQueue queue, uint32_t count,
                                                          const VkSubmitInfo* submits,
                                                          VkFence fence);
  static VKAPI_ATTR VkResult VKAPI_CALL LockedQueueWaitIdle(VkQueue queue);

  bool EnsureSize(size_t width, size_t height);
  void DestroyImages();
  int MemoryType(uint32_t bits, VkMemoryPropertyFlags wanted) const;

  void* library_ = nullptr;
  PFN_vkGetInstanceProcAddr get_instance_proc_ = nullptr;
  VkInstance instance_ = VK_NULL_HANDLE;
  VkPhysicalDevice physical_device_ = VK_NULL_HANDLE;
  VkDevice device_ = VK_NULL_HANDLE;
  VkQueue queue_ = VK_NULL_HANDLE;
  uint32_t queue_family_ = 0;
  std::string description_;
  VkPhysicalDeviceMemoryProperties memory_{};

  // The calls the renderer makes itself.
  struct Calls {
    PFN_vkDestroyInstance DestroyInstance;
    PFN_vkDestroyDevice DestroyDevice;
    PFN_vkGetDeviceProcAddr GetDeviceProcAddr;
    PFN_vkDeviceWaitIdle DeviceWaitIdle;
    PFN_vkCreateImage CreateImage;
    PFN_vkDestroyImage DestroyImage;
    PFN_vkGetImageMemoryRequirements GetImageMemoryRequirements;
    PFN_vkAllocateMemory AllocateMemory;
    PFN_vkFreeMemory FreeMemory;
    PFN_vkBindImageMemory BindImageMemory;
    PFN_vkCreateBuffer CreateBuffer;
    PFN_vkDestroyBuffer DestroyBuffer;
    PFN_vkGetBufferMemoryRequirements GetBufferMemoryRequirements;
    PFN_vkBindBufferMemory BindBufferMemory;
    PFN_vkMapMemory MapMemory;
    PFN_vkUnmapMemory UnmapMemory;
    PFN_vkInvalidateMappedMemoryRanges InvalidateMappedMemoryRanges;
    PFN_vkCreateCommandPool CreateCommandPool;
    PFN_vkDestroyCommandPool DestroyCommandPool;
    PFN_vkAllocateCommandBuffers AllocateCommandBuffers;
    PFN_vkBeginCommandBuffer BeginCommandBuffer;
    PFN_vkEndCommandBuffer EndCommandBuffer;
    PFN_vkResetCommandBuffer ResetCommandBuffer;
    PFN_vkCmdPipelineBarrier CmdPipelineBarrier;
    PFN_vkCmdCopyImageToBuffer CmdCopyImageToBuffer;
    PFN_vkCreateFence CreateFence;
    PFN_vkDestroyFence DestroyFence;
    PFN_vkWaitForFences WaitForFences;
    PFN_vkResetFences ResetFences;
    PFN_vkQueueSubmit QueueSubmit;
    PFN_vkQueueWaitIdle QueueWaitIdle;
    PFN_vkGetMemoryWin32HandlePropertiesKHR GetMemoryWin32HandlePropertiesKHR;
  } vk_{};

  // Whether the device imports D3D11 textures, and its adapter's LUID.
  bool can_import_ = false;
  uint8_t luid_[VK_LUID_SIZE] = {};
  ID3D11Device* d3d_ = nullptr;
  // The ring, guarded by mutex_: the raster thread takes buffers, the main
  // thread gives them back.
  mutable std::mutex mutex_;
  size_t pool_count_ = 0;
  std::vector<PoolBuffer> pool_;
  uint32_t generation_ = 0;
  size_t pool_width_ = 0;
  size_t pool_height_ = 0;
  // The pool buffer the engine is drawing into, -1 when it draws to be read
  // back.
  int drawing_ = -1;
  size_t last_drawn_ = 0;
  GpuFrameCallback gpu_frame_;

  std::vector<Image> images_;
  size_t next_image_ = 0;
  size_t width_ = 0;
  size_t height_ = 0;
  // The readback: a host-visible buffer of one frame, mapped, and the
  // commands that copy an image into it.
  VkBuffer readback_ = VK_NULL_HANDLE;
  VkDeviceMemory readback_memory_ = VK_NULL_HANDLE;
  void* readback_pixels_ = nullptr;
  VkCommandPool command_pool_ = VK_NULL_HANDLE;
  VkCommandBuffer commands_ = VK_NULL_HANDLE;
  VkFence copied_ = VK_NULL_HANDLE;
};

}  // namespace raccoon
#endif  // RACCOON_HAS_VULKAN
