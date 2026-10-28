#if RACCOON_HAS_VULKAN
#include "vulkan_renderer.h"

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>

#include <cstring>

namespace raccoon {

namespace {

// The queue is one, used by the engine on its threads and by the readback
// on the raster thread; the embedder asks for its submits to be locked.
std::mutex g_queue_lock;
PFN_vkQueueSubmit g_queue_submit = nullptr;
PFN_vkQueueWaitIdle g_queue_wait_idle = nullptr;

}  // namespace

VKAPI_ATTR VkResult VKAPI_CALL VulkanRenderer::LockedQueueSubmit(VkQueue queue, uint32_t count,
                                                                 const VkSubmitInfo* submits,
                                                                 VkFence fence) {
  std::lock_guard<std::mutex> lock(g_queue_lock);
  return g_queue_submit(queue, count, submits, fence);
}

VKAPI_ATTR VkResult VKAPI_CALL VulkanRenderer::LockedQueueWaitIdle(VkQueue queue) {
  std::lock_guard<std::mutex> lock(g_queue_lock);
  return g_queue_wait_idle(queue);
}

VulkanRenderer::~VulkanRenderer() { Shutdown(); }

bool VulkanRenderer::Init(std::string* error) {
  HMODULE library = LoadLibraryA("vulkan-1.dll");
  if (library == nullptr) {
    *error = "no vulkan-1.dll";
    return false;
  }
  library_ = library;
  get_instance_proc_ = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
      GetProcAddress(library, "vkGetInstanceProcAddr"));
  if (get_instance_proc_ == nullptr) {
    *error = "no vkGetInstanceProcAddr in vulkan-1.dll";
    return false;
  }
  auto create_instance = reinterpret_cast<PFN_vkCreateInstance>(
      get_instance_proc_(VK_NULL_HANDLE, "vkCreateInstance"));
  VkApplicationInfo application{VK_STRUCTURE_TYPE_APPLICATION_INFO};
  application.pApplicationName = "raccoon_runner";
  application.apiVersion = kApiVersion;
  VkInstanceCreateInfo instance_info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
  instance_info.pApplicationInfo = &application;
  if (create_instance == nullptr ||
      create_instance(&instance_info, nullptr, &instance_) != VK_SUCCESS) {
    *error = "vkCreateInstance failed";
    return false;
  }
  auto instance_call = [this](const char* name) {
    return get_instance_proc_(instance_, name);
  };
  vk_.DestroyInstance = reinterpret_cast<PFN_vkDestroyInstance>(instance_call("vkDestroyInstance"));
  auto enumerate = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(
      instance_call("vkEnumeratePhysicalDevices"));
  auto properties_of = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(
      instance_call("vkGetPhysicalDeviceProperties"));
  auto families_of = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
      instance_call("vkGetPhysicalDeviceQueueFamilyProperties"));
  auto memory_of = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
      instance_call("vkGetPhysicalDeviceMemoryProperties"));
  auto create_device = reinterpret_cast<PFN_vkCreateDevice>(instance_call("vkCreateDevice"));

  // The GPU of DXGI's first adapter, the one Flutter's Windows embedding
  // draws on by default: a client can open a shared texture only on the
  // GPU that made it. Else the first device with a graphics queue.
  LUID default_luid{};
  bool has_default = false;
  IDXGIFactory1* factory = nullptr;
  if (SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory)))) {
    IDXGIAdapter1* adapter = nullptr;
    if (factory->EnumAdapters1(0, &adapter) == S_OK) {
      DXGI_ADAPTER_DESC1 adapter_description{};
      adapter->GetDesc1(&adapter_description);
      default_luid = adapter_description.AdapterLuid;
      has_default = true;
      adapter->Release();
    }
    factory->Release();
  }
  auto properties2_of = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(
      instance_call("vkGetPhysicalDeviceProperties2"));
  uint32_t count = 0;
  enumerate(instance_, &count, nullptr);
  std::vector<VkPhysicalDevice> devices(count);
  enumerate(instance_, &count, devices.data());
  for (VkPhysicalDevice candidate : devices) {
    uint32_t family_count = 0;
    families_of(candidate, &family_count, nullptr);
    std::vector<VkQueueFamilyProperties> families(family_count);
    families_of(candidate, &family_count, families.data());
    int graphics = -1;
    for (uint32_t i = 0; i < family_count && graphics < 0; ++i) {
      if (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) graphics = static_cast<int>(i);
    }
    if (graphics < 0) continue;
    VkPhysicalDeviceIDProperties ids{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
    VkPhysicalDeviceProperties2 properties2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
    properties2.pNext = &ids;
    if (properties2_of != nullptr) properties2_of(candidate, &properties2);
    const bool is_default = has_default && ids.deviceLUIDValid &&
                            std::memcmp(ids.deviceLUID, &default_luid, sizeof(LUID)) == 0;
    if (physical_device_ == VK_NULL_HANDLE || is_default) {
      physical_device_ = candidate;
      queue_family_ = static_cast<uint32_t>(graphics);
    }
    if (is_default) break;
  }
  if (physical_device_ == VK_NULL_HANDLE) {
    *error = "no Vulkan device with a graphics queue";
    return false;
  }
  VkPhysicalDeviceProperties properties{};
  properties_of(physical_device_, &properties);
  description_ = properties.deviceName;
  memory_of(physical_device_, &memory_);

  // Importing D3D11 textures, for the pool: the extension, and the
  // adapter's LUID to make the D3D11 device on the same GPU.
  auto device_extensions = reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(
      instance_call("vkEnumerateDeviceExtensionProperties"));
  uint32_t extension_count = 0;
  device_extensions(physical_device_, nullptr, &extension_count, nullptr);
  std::vector<VkExtensionProperties> extensions(extension_count);
  device_extensions(physical_device_, nullptr, &extension_count, extensions.data());
  for (const VkExtensionProperties& extension : extensions) {
    if (std::strcmp(extension.extensionName, VK_KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME) == 0) {
      can_import_ = true;
    }
  }
  VkPhysicalDeviceIDProperties ids{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
  VkPhysicalDeviceProperties2 properties2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
  properties2.pNext = &ids;
  if (properties2_of != nullptr) properties2_of(physical_device_, &properties2);
  can_import_ = can_import_ && ids.deviceLUIDValid;
  std::memcpy(luid_, ids.deviceLUID, VK_LUID_SIZE);
  const char* enabled[] = {VK_KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME};

  const float priority = 1.0f;
  VkDeviceQueueCreateInfo queue_info{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
  queue_info.queueFamilyIndex = queue_family_;
  queue_info.queueCount = 1;
  queue_info.pQueuePriorities = &priority;
  VkDeviceCreateInfo device_info{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
  device_info.queueCreateInfoCount = 1;
  device_info.pQueueCreateInfos = &queue_info;
  if (can_import_) {
    device_info.enabledExtensionCount = 1;
    device_info.ppEnabledExtensionNames = enabled;
  }
  if (create_device(physical_device_, &device_info, nullptr, &device_) != VK_SUCCESS) {
    *error = "vkCreateDevice failed on " + description_;
    return false;
  }
  vk_.GetDeviceProcAddr =
      reinterpret_cast<PFN_vkGetDeviceProcAddr>(instance_call("vkGetDeviceProcAddr"));
  auto device_call = [this](const char* name) { return vk_.GetDeviceProcAddr(device_, name); };
#define RACCOON_VK(name) vk_.name = reinterpret_cast<PFN_vk##name>(device_call("vk" #name))
  RACCOON_VK(DestroyDevice);
  RACCOON_VK(DeviceWaitIdle);
  RACCOON_VK(CreateImage);
  RACCOON_VK(DestroyImage);
  RACCOON_VK(GetImageMemoryRequirements);
  RACCOON_VK(AllocateMemory);
  RACCOON_VK(FreeMemory);
  RACCOON_VK(BindImageMemory);
  RACCOON_VK(CreateBuffer);
  RACCOON_VK(DestroyBuffer);
  RACCOON_VK(GetBufferMemoryRequirements);
  RACCOON_VK(BindBufferMemory);
  RACCOON_VK(MapMemory);
  RACCOON_VK(UnmapMemory);
  RACCOON_VK(InvalidateMappedMemoryRanges);
  RACCOON_VK(CreateCommandPool);
  RACCOON_VK(DestroyCommandPool);
  RACCOON_VK(AllocateCommandBuffers);
  RACCOON_VK(BeginCommandBuffer);
  RACCOON_VK(EndCommandBuffer);
  RACCOON_VK(ResetCommandBuffer);
  RACCOON_VK(CmdPipelineBarrier);
  RACCOON_VK(CmdCopyImageToBuffer);
  RACCOON_VK(CreateFence);
  RACCOON_VK(DestroyFence);
  RACCOON_VK(WaitForFences);
  RACCOON_VK(ResetFences);
  RACCOON_VK(QueueSubmit);
  RACCOON_VK(QueueWaitIdle);
  if (can_import_) RACCOON_VK(GetMemoryWin32HandlePropertiesKHR);
#undef RACCOON_VK
  g_queue_submit = vk_.QueueSubmit;
  g_queue_wait_idle = vk_.QueueWaitIdle;
  auto get_queue = reinterpret_cast<PFN_vkGetDeviceQueue>(device_call("vkGetDeviceQueue"));
  get_queue(device_, queue_family_, 0, &queue_);

  VkCommandPoolCreateInfo pool_info{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
  pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
  pool_info.queueFamilyIndex = queue_family_;
  if (vk_.CreateCommandPool(device_, &pool_info, nullptr, &command_pool_) != VK_SUCCESS) {
    *error = "no command pool on " + description_;
    return false;
  }
  VkCommandBufferAllocateInfo command_info{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
  command_info.commandPool = command_pool_;
  command_info.commandBufferCount = 1;
  command_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
  VkFenceCreateInfo fence_info{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  if (vk_.AllocateCommandBuffers(device_, &command_info, &commands_) != VK_SUCCESS ||
      vk_.CreateFence(device_, &fence_info, nullptr, &copied_) != VK_SUCCESS) {
    *error = "no command buffer or fence on " + description_;
    return false;
  }
  return true;
}

void VulkanRenderer::Shutdown() {
  if (device_ != VK_NULL_HANDLE) {
    vk_.DeviceWaitIdle(device_);
    DestroyImages();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      DestroyPool();
    }
    if (d3d_ != nullptr) {
      d3d_->Release();
      d3d_ = nullptr;
    }
    if (copied_ != VK_NULL_HANDLE) vk_.DestroyFence(device_, copied_, nullptr);
    if (command_pool_ != VK_NULL_HANDLE) vk_.DestroyCommandPool(device_, command_pool_, nullptr);
    vk_.DestroyDevice(device_, nullptr);
    device_ = VK_NULL_HANDLE;
  }
  if (instance_ != VK_NULL_HANDLE) {
    vk_.DestroyInstance(instance_, nullptr);
    instance_ = VK_NULL_HANDLE;
  }
}

void* VulkanRenderer::ProcAddress(VkInstance instance, const char* name) const {
  if (std::strcmp(name, "vkQueueSubmit") == 0) {
    return reinterpret_cast<void*>(&LockedQueueSubmit);
  }
  if (std::strcmp(name, "vkQueueWaitIdle") == 0) {
    return reinterpret_cast<void*>(&LockedQueueWaitIdle);
  }
  return reinterpret_cast<void*>(get_instance_proc_(instance, name));
}

int VulkanRenderer::MemoryType(uint32_t bits, VkMemoryPropertyFlags wanted) const {
  for (uint32_t i = 0; i < memory_.memoryTypeCount; ++i) {
    if ((bits & (1u << i)) && (memory_.memoryTypes[i].propertyFlags & wanted) == wanted) {
      return static_cast<int>(i);
    }
  }
  return -1;
}

void VulkanRenderer::DestroyImages() {
  for (Image& image : images_) {
    vk_.DestroyImage(device_, image.image, nullptr);
    vk_.FreeMemory(device_, image.memory, nullptr);
  }
  images_.clear();
  if (readback_memory_ != VK_NULL_HANDLE) {
    vk_.UnmapMemory(device_, readback_memory_);
    vk_.DestroyBuffer(device_, readback_, nullptr);
    vk_.FreeMemory(device_, readback_memory_, nullptr);
  }
  readback_ = VK_NULL_HANDLE;
  readback_memory_ = VK_NULL_HANDLE;
  readback_pixels_ = nullptr;
  width_ = height_ = 0;
}

bool VulkanRenderer::EnsureSize(size_t width, size_t height) {
  if (width == width_ && height == height_ && !images_.empty()) return true;
  vk_.DeviceWaitIdle(device_);
  DestroyImages();
  for (size_t i = 0; i < kImages; ++i) {
    // The usage the engine wraps the image with: drawn to, copied from and
    // to, sampled.
    VkImageCreateInfo image_info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    image_info.imageType = VK_IMAGE_TYPE_2D;
    image_info.format = kFormat;
    image_info.extent = {static_cast<uint32_t>(width), static_cast<uint32_t>(height), 1};
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = VK_SAMPLE_COUNT_1_BIT;
    image_info.tiling = VK_IMAGE_TILING_OPTIMAL;
    image_info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                       VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    Image image;
    if (vk_.CreateImage(device_, &image_info, nullptr, &image.image) != VK_SUCCESS) return false;
    VkMemoryRequirements needs{};
    vk_.GetImageMemoryRequirements(device_, image.image, &needs);
    const int type = MemoryType(needs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkMemoryAllocateInfo allocate{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    allocate.allocationSize = needs.size;
    allocate.memoryTypeIndex = static_cast<uint32_t>(type);
    if (type < 0 || vk_.AllocateMemory(device_, &allocate, nullptr, &image.memory) != VK_SUCCESS ||
        vk_.BindImageMemory(device_, image.image, image.memory, 0) != VK_SUCCESS) {
      vk_.DestroyImage(device_, image.image, nullptr);
      return false;
    }
    images_.push_back(image);
  }
  // Read back through cached memory where there is some: the CPU reads
  // every byte of it.
  VkBufferCreateInfo buffer_info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
  buffer_info.size = width * height * 4;
  buffer_info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
  if (vk_.CreateBuffer(device_, &buffer_info, nullptr, &readback_) != VK_SUCCESS) return false;
  VkMemoryRequirements needs{};
  vk_.GetBufferMemoryRequirements(device_, readback_, &needs);
  int type = MemoryType(needs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                  VK_MEMORY_PROPERTY_HOST_CACHED_BIT);
  if (type < 0) {
    type = MemoryType(needs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
  }
  VkMemoryAllocateInfo allocate{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
  allocate.allocationSize = needs.size;
  allocate.memoryTypeIndex = static_cast<uint32_t>(type);
  if (type < 0 || vk_.AllocateMemory(device_, &allocate, nullptr, &readback_memory_) != VK_SUCCESS ||
      vk_.BindBufferMemory(device_, readback_, readback_memory_, 0) != VK_SUCCESS ||
      vk_.MapMemory(device_, readback_memory_, 0, VK_WHOLE_SIZE, 0, &readback_pixels_) !=
          VK_SUCCESS) {
    return false;
  }
  width_ = width;
  height_ = height;
  return true;
}

VkImage VulkanRenderer::NextImage(size_t width, size_t height) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    drawing_ = -1;
    if (pool_count_ > 0 && EnsurePool(width, height)) {
      // Round the ring from the buffer after the last one drawn, so one
      // just given back is drawn into last.
      for (size_t step = 1; step <= pool_.size(); ++step) {
        const size_t i = (last_drawn_ + step) % pool_.size();
        if (pool_[i].busy) continue;
        pool_[i].busy = true;
        drawing_ = static_cast<int>(i);
        last_drawn_ = i;
        return pool_[i].image.image;
      }
    }
  }
  // No pool, or every buffer is out: this frame is read back.
  if (!EnsureSize(width, height)) return VK_NULL_HANDLE;
  next_image_ = (next_image_ + 1) % images_.size();
  return images_[next_image_].image;
}

bool VulkanRenderer::Present(VkImage image, const FrameCallback& callback) {
  int index = -1;
  uint32_t generation = 0;
  size_t width = 0;
  size_t height = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (drawing_ >= 0 && static_cast<size_t>(drawing_) < pool_.size() &&
        pool_[drawing_].image.image == image) {
      index = drawing_;
      generation = generation_;
      width = pool_width_;
      height = pool_height_;
    }
    drawing_ = -1;
  }
  if (index >= 0) {
    // Handed over to whoever opens the texture: out of the engine's layout
    // and its queue family, for D3D11 to read.
    if (!Transition(image, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
                    VK_QUEUE_FAMILY_EXTERNAL)) {
      Release(generation, index, -1);
      return false;
    }
    if (gpu_frame_) {
      gpu_frame_(generation, index, width, height, -1);
    } else {
      Release(generation, index, -1);
    }
    return true;
  }
  if (readback_pixels_ == nullptr) return false;
  vk_.ResetCommandBuffer(commands_, 0);
  VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
  begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
  vk_.BeginCommandBuffer(commands_, &begin);
  // The engine leaves the image as it drew it, a colour attachment.
  VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
  barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
  barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
  barrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
  barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
  barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  barrier.image = image;
  barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
  vk_.CmdPipelineBarrier(commands_, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
  VkBufferImageCopy region{};
  region.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
  region.imageExtent = {static_cast<uint32_t>(width_), static_cast<uint32_t>(height_), 1};
  vk_.CmdCopyImageToBuffer(commands_, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback_, 1,
                           &region);
  // Back as the engine had it.
  barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
  barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
  barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
  barrier.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
  vk_.CmdPipelineBarrier(commands_, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, nullptr, 0, nullptr,
                         1, &barrier);
  vk_.EndCommandBuffer(commands_);
  VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
  submit.commandBufferCount = 1;
  submit.pCommandBuffers = &commands_;
  vk_.ResetFences(device_, 1, &copied_);
  if (LockedQueueSubmit(queue_, 1, &submit, copied_) != VK_SUCCESS ||
      vk_.WaitForFences(device_, 1, &copied_, VK_TRUE, UINT64_MAX) != VK_SUCCESS) {
    return false;
  }
  VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
  range.memory = readback_memory_;
  range.size = VK_WHOLE_SIZE;
  vk_.InvalidateMappedMemoryRanges(device_, 1, &range);
  callback(readback_pixels_, width_ * 4, height_, kFormat == VK_FORMAT_B8G8R8A8_UNORM);
  return true;
}

bool VulkanRenderer::Transition(VkImage image, VkImageLayout from, VkImageLayout to,
                                uint32_t to_family) {
  vk_.ResetCommandBuffer(commands_, 0);
  VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
  begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
  vk_.BeginCommandBuffer(commands_, &begin);
  VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
  barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
  barrier.dstAccessMask = 0;
  barrier.oldLayout = from;
  barrier.newLayout = to;
  barrier.srcQueueFamilyIndex = to_family == VK_QUEUE_FAMILY_IGNORED ? to_family : queue_family_;
  barrier.dstQueueFamilyIndex = to_family;
  barrier.image = image;
  barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
  vk_.CmdPipelineBarrier(commands_, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                         VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 1,
                         &barrier);
  vk_.EndCommandBuffer(commands_);
  VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
  submit.commandBufferCount = 1;
  submit.pCommandBuffers = &commands_;
  vk_.ResetFences(device_, 1, &copied_);
  return LockedQueueSubmit(queue_, 1, &submit, copied_) == VK_SUCCESS &&
         vk_.WaitForFences(device_, 1, &copied_, VK_TRUE, UINT64_MAX) == VK_SUCCESS;
}

bool VulkanRenderer::EnsureD3d(std::string* error) {
  if (d3d_ != nullptr) return true;
  IDXGIFactory1* factory = nullptr;
  if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory)))) {
    *error = "no DXGI factory";
    return false;
  }
  IDXGIAdapter1* adapter = nullptr;
  for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; ++i) {
    DXGI_ADAPTER_DESC1 description{};
    adapter->GetDesc1(&description);
    if (std::memcmp(&description.AdapterLuid, luid_, sizeof(LUID)) == 0) break;
    adapter->Release();
    adapter = nullptr;
  }
  factory->Release();
  if (adapter == nullptr) {
    *error = "no DXGI adapter for " + description_;
    return false;
  }
  const HRESULT made =
      D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, nullptr, 0,
                        D3D11_SDK_VERSION, &d3d_, nullptr, nullptr);
  adapter->Release();
  if (FAILED(made)) {
    *error = "no D3D11 device on " + description_;
    return false;
  }
  return true;
}

bool VulkanRenderer::EnablePool(size_t count, std::string* error) {
  if (!can_import_) {
    *error = description_ + " imports no D3D11 textures";
    return false;
  }
  if (!EnsureD3d(error)) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  if (pool_count_ != count) DestroyPool();
  pool_count_ = count;
  return true;
}

void VulkanRenderer::DisablePool() {
  std::lock_guard<std::mutex> lock(mutex_);
  pool_count_ = 0;
  DestroyPool();
}

void VulkanRenderer::DestroyPool() {
  if (pool_.empty()) return;
  vk_.DeviceWaitIdle(device_);
  for (PoolBuffer& buffer : pool_) {
    vk_.DestroyImage(device_, buffer.image.image, nullptr);
    vk_.FreeMemory(device_, buffer.image.memory, nullptr);
    // A client that opened the texture keeps it alive until it lets go.
    buffer.texture->Release();
  }
  pool_.clear();
  pool_width_ = pool_height_ = 0;
  if (drawing_ >= 0) drawing_ = -1;
}

bool VulkanRenderer::EnsurePool(size_t width, size_t height) {
  if (!pool_.empty() && width == pool_width_ && height == pool_height_) return true;
  DestroyPool();
  for (size_t i = 0; i < pool_count_; ++i) {
    PoolBuffer buffer;
    D3D11_TEXTURE2D_DESC description{};
    description.Width = static_cast<UINT>(width);
    description.Height = static_cast<UINT>(height);
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    // A legacy shared handle: what Flutter's texture registrar opens.
    description.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    IDXGIResource* resource = nullptr;
    HANDLE shared = nullptr;
    if (FAILED(d3d_->CreateTexture2D(&description, nullptr, &buffer.texture))) break;
    pool_.push_back(buffer);
    if (FAILED(buffer.texture->QueryInterface(__uuidof(IDXGIResource),
                                              reinterpret_cast<void**>(&resource))) ||
        FAILED(resource->GetSharedHandle(&shared))) {
      if (resource != nullptr) resource->Release();
      break;
    }
    resource->Release();
    pool_.back().shared_handle = shared;

    VkExternalMemoryImageCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO};
    external.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT;
    VkImageCreateInfo image_info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    image_info.pNext = &external;
    image_info.imageType = VK_IMAGE_TYPE_2D;
    image_info.format = kFormat;
    image_info.extent = {static_cast<uint32_t>(width), static_cast<uint32_t>(height), 1};
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = VK_SAMPLE_COUNT_1_BIT;
    image_info.tiling = VK_IMAGE_TILING_OPTIMAL;
    image_info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                       VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkImage image = VK_NULL_HANDLE;
    if (vk_.CreateImage(device_, &image_info, nullptr, &image) != VK_SUCCESS) break;
    pool_.back().image.image = image;
    VkMemoryWin32HandlePropertiesKHR handle_properties{
        VK_STRUCTURE_TYPE_MEMORY_WIN32_HANDLE_PROPERTIES_KHR};
    vk_.GetMemoryWin32HandlePropertiesKHR(device_,
                                          VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT,
                                          shared, &handle_properties);
    VkMemoryRequirements needs{};
    vk_.GetImageMemoryRequirements(device_, image, &needs);
    const uint32_t bits = needs.memoryTypeBits & (handle_properties.memoryTypeBits != 0
                                                      ? handle_properties.memoryTypeBits
                                                      : ~0u);
    const int type = MemoryType(bits, 0);
    VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
    dedicated.image = image;
    VkImportMemoryWin32HandleInfoKHR import{VK_STRUCTURE_TYPE_IMPORT_MEMORY_WIN32_HANDLE_INFO_KHR};
    import.pNext = &dedicated;
    import.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT;
    import.handle = shared;
    VkMemoryAllocateInfo allocate{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    allocate.pNext = &import;
    allocate.allocationSize = needs.size;
    allocate.memoryTypeIndex = static_cast<uint32_t>(type);
    VkDeviceMemory memory = VK_NULL_HANDLE;
    if (type < 0 || vk_.AllocateMemory(device_, &allocate, nullptr, &memory) != VK_SUCCESS) break;
    pool_.back().image.memory = memory;
    if (vk_.BindImageMemory(device_, image, memory, 0) != VK_SUCCESS) break;
  }
  const bool built = !pool_.empty() && pool_.size() == pool_count_ &&
                     pool_.back().image.memory != VK_NULL_HANDLE;
  if (!built) {
    // What was made is let go, and the frames are read back.
    for (PoolBuffer& buffer : pool_) {
      if (buffer.image.image != VK_NULL_HANDLE) {
        vk_.DestroyImage(device_, buffer.image.image, nullptr);
      }
      if (buffer.image.memory != VK_NULL_HANDLE) {
        vk_.FreeMemory(device_, buffer.image.memory, nullptr);
      }
      buffer.texture->Release();
    }
    pool_.clear();
    pool_count_ = 0;
    return false;
  }
  pool_width_ = width;
  pool_height_ = height;
  ++generation_;
  return true;
}

bool VulkanRenderer::pool_set(GpuBufferSet* out) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (pool_.empty()) return false;
  out->generation = generation_;
  out->width = pool_width_;
  out->height = pool_height_;
  out->fourcc = 0x42475241;  // 'BGRA'
  out->modifier = 0;
  out->strides.clear();
  out->offsets.clear();
  out->fds.clear();
  out->surface_ids.clear();
  for (const PoolBuffer& buffer : pool_) {
    out->strides.push_back(static_cast<uint32_t>(pool_width_ * 4));
    out->offsets.push_back(0);
    // Legacy shared handles are 32-bit values, the same in every process.
    out->surface_ids.push_back(
        static_cast<uint32_t>(reinterpret_cast<uintptr_t>(buffer.shared_handle)));
  }
  return true;
}

bool VulkanRenderer::HasFreeBuffer() const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (pool_.empty()) return true;
  for (const PoolBuffer& buffer : pool_) {
    if (!buffer.busy) return true;
  }
  return false;
}

void VulkanRenderer::Release(uint32_t generation, int index, int) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (generation != generation_ || index < 0 || static_cast<size_t>(index) >= pool_.size()) {
    return;
  }
  pool_[index].busy = false;
}

void VulkanRenderer::ReleaseAll() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (PoolBuffer& buffer : pool_) buffer.busy = false;
}

}  // namespace raccoon
#endif  // RACCOON_HAS_VULKAN
