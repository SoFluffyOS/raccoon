// raccoon_gpu_handle_check <gpu socket>: checks that a GPU socket client on
// Windows can open the ring's textures by their shared handles, as
// Flutter's texture registrar does, and that the frame drawn into them is
// the app's. Waits for the ring ('RGPU'), opens every handle on a D3D11
// device of the default adapter, copies each texture to the CPU and looks
// at pixel (5, 5) for example/hello's blue (30, 136, 229). Passes when every
// handle opens and one texture holds the frame. Prints one line; exits 0 on
// a pass.
#include <winsock2.h>
#include <afunix.h>
#include <windows.h>
#include <d3d11.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

uint32_t Read32(const uint8_t* at) {
  return static_cast<uint32_t>(at[0]) | (static_cast<uint32_t>(at[1]) << 8) |
         (static_cast<uint32_t>(at[2]) << 16) | (static_cast<uint32_t>(at[3]) << 24);
}

int Fail(const std::string& why) {
  std::printf("HANDLES failed: %s\n", why.c_str());
  return 1;
}

// One framed message from the socket, or empty when it hung up.
std::vector<uint8_t> ReadMessage(SOCKET socket) {
  auto read_exactly = [socket](uint8_t* into, size_t size) {
    size_t got = 0;
    while (got < size) {
      const int n = recv(socket, reinterpret_cast<char*>(into + got), static_cast<int>(size - got), 0);
      if (n <= 0) return false;
      got += static_cast<size_t>(n);
    }
    return true;
  };
  uint8_t prefix[4];
  if (!read_exactly(prefix, 4)) return {};
  std::vector<uint8_t> message(Read32(prefix));
  if (!read_exactly(message.data(), message.size())) return {};
  return message;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) return Fail("usage: raccoon_gpu_handle_check <gpu socket>");
  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
  SOCKET socket = ::socket(AF_UNIX, SOCK_STREAM, 0);
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::strncpy(address.sun_path, argv[1], sizeof(address.sun_path) - 1);
  if (connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
    return Fail(std::string("cannot connect to ") + argv[1]);
  }
  std::vector<uint8_t> set;
  while (true) {
    set = ReadMessage(socket);
    if (set.empty()) return Fail("the runner hung up before describing a ring");
    if (set.size() >= 32 && std::memcmp(set.data(), "RGPU", 4) == 0) break;
  }
  const uint32_t count = Read32(set.data() + 8);
  const uint32_t width = Read32(set.data() + 12);
  const uint32_t height = Read32(set.data() + 16);
  if (set.size() != 32 + count * 8 + count * 4) {
    return Fail("a ring of " + std::to_string(count) + " with " + std::to_string(set.size()) +
                " bytes, no handles after the pairs");
  }

  ID3D11Device* device = nullptr;
  ID3D11DeviceContext* context = nullptr;
  if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
                               D3D11_SDK_VERSION, &device, nullptr, &context))) {
    return Fail("no D3D11 device");
  }
  D3D11_TEXTURE2D_DESC staging_description{};
  staging_description.Width = width;
  staging_description.Height = height;
  staging_description.MipLevels = 1;
  staging_description.ArraySize = 1;
  staging_description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  staging_description.SampleDesc.Count = 1;
  staging_description.Usage = D3D11_USAGE_STAGING;
  staging_description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ID3D11Texture2D* staging = nullptr;
  if (FAILED(device->CreateTexture2D(&staging_description, nullptr, &staging))) {
    return Fail("no staging texture");
  }
  int opened = 0;
  int drawn = 0;
  for (uint32_t i = 0; i < count; ++i) {
    const uintptr_t value = Read32(set.data() + 32 + count * 8 + i * 4);
    ID3D11Texture2D* texture = nullptr;
    if (FAILED(device->OpenSharedResource(reinterpret_cast<HANDLE>(value), __uuidof(ID3D11Texture2D),
                                          reinterpret_cast<void**>(&texture)))) {
      continue;
    }
    ++opened;
    context->CopyResource(staging, texture);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (SUCCEEDED(context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped))) {
      const auto* pixel = static_cast<const uint8_t*>(mapped.pData) + 5 * mapped.RowPitch + 5 * 4;
      // BGRA: blue 229, green 136, red 30.
      if (pixel[0] == 229 && pixel[1] == 136 && pixel[2] == 30) ++drawn;
      context->Unmap(staging, 0);
    }
    texture->Release();
  }
  if (opened != static_cast<int>(count)) {
    return Fail(std::to_string(opened) + " of " + std::to_string(count) + " handles opened");
  }
  if (drawn == 0) return Fail("no texture holds the app's frame");
  std::printf("HANDLES ok: %d of %u opened, %d with the frame\n", opened, count, drawn);
  return 0;
}
