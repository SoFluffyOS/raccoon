#if RACCOON_HAS_VULKAN
#include "vulkan_renderer.h"

#include <windows.h>

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

  // The first device with a graphics queue, as the system lists them: the
  // one Windows would use by default.
  uint32_t count = 0;
  enumerate(instance_, &count, nullptr);
  std::vector<VkPhysicalDevice> devices(count);
  enumerate(instance_, &count, devices.data());
  for (VkPhysicalDevice candidate : devices) {
    uint32_t family_count = 0;
    families_of(candidate, &family_count, nullptr);
    std::vector<VkQueueFamilyProperties> families(family_count);
    families_of(candidate, &family_count, families.data());
    for (uint32_t i = 0; i < family_count; ++i) {
      if (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
        physical_device_ = candidate;
        queue_family_ = i;
        break;
      }
    }
    if (physical_device_ != VK_NULL_HANDLE) break;
  }
  if (physical_device_ == VK_NULL_HANDLE) {
    *error = "no Vulkan device with a graphics queue";
    return false;
  }
  VkPhysicalDeviceProperties properties{};
  properties_of(physical_device_, &properties);
  description_ = properties.deviceName;
  memory_of(physical_device_, &memory_);

  const float priority = 1.0f;
  VkDeviceQueueCreateInfo queue_info{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
  queue_info.queueFamilyIndex = queue_family_;
  queue_info.queueCount = 1;
  queue_info.pQueuePriorities = &priority;
  VkDeviceCreateInfo device_info{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
  device_info.queueCreateInfoCount = 1;
  device_info.pQueueCreateInfos = &queue_info;
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
  if (!EnsureSize(width, height)) return VK_NULL_HANDLE;
  next_image_ = (next_image_ + 1) % images_.size();
  return images_[next_image_].image;
}

bool VulkanRenderer::Present(VkImage image, const FrameCallback& callback) {
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
  callback(readback_pixels_, width_ * 4, height_);
  return true;
}

}  // namespace raccoon
#endif  // RACCOON_HAS_VULKAN
