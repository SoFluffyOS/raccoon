// raccoon_gpu_port_check <gpu socket>: checks that a GPU socket client gets
// the ring's IOSurfaces by Mach port (surface_port_server.h) on macOS. Asks
// for them ('RPRT'), takes the service and token ('RSVC'), waits for the
// ring built after that ('RGPU'), and asks the service for its surfaces.
// Passes when every surface comes, at the ring's size, none of them can be
// looked up by ID any more, and a request with a wrong token gets none.
// Prints one line; exits 0 on a pass.
#include <IOSurface/IOSurface.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr mach_msg_id_t kRequestId = 0x52505254;  // 'RPRT'
constexpr mach_msg_id_t kReplyId = 0x52505259;    // 'RPRY'
constexpr size_t kTokenSize = 16;

uint32_t Read32(const uint8_t* at) {
  return static_cast<uint32_t>(at[0]) | (static_cast<uint32_t>(at[1]) << 8) |
         (static_cast<uint32_t>(at[2]) << 16) | (static_cast<uint32_t>(at[3]) << 24);
}

int Fail(const std::string& why) {
  std::printf("PORTS failed: %s\n", why.c_str());
  return 1;
}

// One request to the service; the surfaces' send rights, empty when refused.
std::vector<mach_port_t> AskPorts(mach_port_t service, uint32_t generation, const uint8_t* token) {
  mach_port_t reply = MACH_PORT_NULL;
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply);
  struct Request {
    mach_msg_header_t header;
    uint32_t generation;
    uint8_t token[kTokenSize];
  };
  // One buffer for the request and the reply: a send and receive in one
  // call receives into the buffer it sent from.
  union {
    Request request;
    mach_msg_header_t header;
    uint8_t bytes[1024];
  } message{};
  message.request.header.msgh_bits =
      MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
  message.request.header.msgh_size = sizeof(Request);
  message.request.header.msgh_remote_port = service;
  message.request.header.msgh_local_port = reply;
  message.request.header.msgh_id = kRequestId;
  message.request.generation = generation;
  std::memcpy(message.request.token, token, kTokenSize);
  std::vector<mach_port_t> ports;
  auto& answer = message;
  if (mach_msg(&message.header, MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT,
               sizeof(Request), sizeof(message), reply, 2000, MACH_PORT_NULL) == MACH_MSG_SUCCESS &&
      answer.header.msgh_id == kReplyId && (answer.header.msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
    const auto* body = reinterpret_cast<const mach_msg_body_t*>(&answer.header + 1);
    const auto* descriptors = reinterpret_cast<const mach_msg_port_descriptor_t*>(body + 1);
    for (mach_msg_size_t i = 0; i < body->msgh_descriptor_count; ++i) {
      ports.push_back(descriptors[i].name);
    }
  }
  mach_port_mod_refs(mach_task_self(), reply, MACH_PORT_RIGHT_RECEIVE, -1);
  return ports;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) return Fail("usage: raccoon_gpu_port_check <gpu socket>");
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::strncpy(address.sun_path, argv[1], sizeof(address.sun_path) - 1);
  const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0 || connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
    return Fail(std::string("cannot connect to ") + argv[1]);
  }
  const uint8_t ask[] = {4, 0, 0, 0, 'R', 'P', 'R', 'T'};
  send(fd, ask, sizeof(ask), 0);

  std::string service;
  uint8_t token[kTokenSize] = {};
  std::vector<uint8_t> inbox;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  timeval wait{0, 200000};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof(wait));
  while (std::chrono::steady_clock::now() < deadline) {
    uint8_t buffer[4096];
    const ssize_t got = recv(fd, buffer, sizeof(buffer), 0);
    if (got == 0) return Fail("the runner hung up");
    if (got > 0) inbox.insert(inbox.end(), buffer, buffer + got);
    size_t offset = 0;
    while (inbox.size() - offset >= 4) {
      const uint32_t length = Read32(inbox.data() + offset);
      if (inbox.size() - offset - 4 < length) break;
      const uint8_t* payload = inbox.data() + offset + 4;
      offset += 4 + length;
      if (length >= 8 && std::memcmp(payload, "RSVC", 4) == 0) {
        const uint32_t size = Read32(payload + 4);
        if (length < 8 + size + kTokenSize) return Fail("a short RSVC");
        service.assign(reinterpret_cast<const char*>(payload + 8), size);
        std::memcpy(token, payload + 8 + size, kTokenSize);
        continue;
      }
      // Only a ring announced after the answer is built without global
      // surfaces.
      if (service.empty() || length < 32 || std::memcmp(payload, "RGPU", 4) != 0) continue;
      const uint32_t generation = Read32(payload + 4);
      const uint32_t count = Read32(payload + 8);
      const uint32_t width = Read32(payload + 12);
      const uint32_t height = Read32(payload + 16);
      mach_port_t port = MACH_PORT_NULL;
      if (bootstrap_look_up(bootstrap_port, service.c_str(), &port) != KERN_SUCCESS) {
        return Fail("no service " + service);
      }
      // Not global: no lookup by ID, checked before this process holds any
      // of them (a process finds the surfaces it holds by ID).
      const uint8_t* ids = payload + 32 + count * 8;
      if (length >= 32 + count * 12) {
        for (uint32_t i = 0; i < count; ++i) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
          IOSurfaceRef by_id = IOSurfaceLookup(Read32(ids + i * 4));
#pragma clang diagnostic pop
          if (by_id != nullptr) {
            CFRelease(by_id);
            return Fail("a surface is still global");
          }
        }
      }
      uint8_t wrong[kTokenSize] = {};
      if (!AskPorts(port, generation, wrong).empty()) return Fail("a wrong token got ports");
      const std::vector<mach_port_t> ports = AskPorts(port, generation, token);
      if (ports.size() != count) {
        return Fail("asked for " + std::to_string(count) + " surfaces, got " +
                    std::to_string(ports.size()));
      }
      std::vector<IOSurfaceRef> surfaces;
      for (uint32_t i = 0; i < count; ++i) {
        IOSurfaceRef surface = IOSurfaceLookupFromMachPort(ports[i]);
        mach_port_deallocate(mach_task_self(), ports[i]);
        if (surface == nullptr) return Fail("a port with no surface");
        surfaces.push_back(surface);
        if (IOSurfaceGetWidth(surface) != width || IOSurfaceGetHeight(surface) != height) {
          return Fail("a surface of the wrong size");
        }
      }
      // The engine draws into these: some surface holds pixels once it
      // has, which a slow machine takes a while to (#79).
      bool drawn = false;
      const auto draw_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
      while (!drawn && std::chrono::steady_clock::now() < draw_deadline) {
        usleep(100000);
        for (IOSurfaceRef surface : surfaces) {
          IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
          const auto* bytes = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(surface));
          const size_t size = IOSurfaceGetAllocSize(surface);
          for (size_t at = 0; at < size && !drawn; ++at) drawn = bytes[at] != 0;
          IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
        }
      }
      for (IOSurfaceRef surface : surfaces) CFRelease(surface);
      if (!drawn) return Fail("no surface holds a drawn frame in 5 s");
      std::printf("PORTS ok: %u surfaces of %ux%u by port from %s, drawn into, none by ID\n",
                  count, width, height, service.c_str());
      return 0;
    }
    inbox.erase(inbox.begin(), inbox.begin() + offset);
  }
  return Fail(service.empty() ? "no RSVC: this runner does not hand out ports"
                              : "no ring came after the answer");
}
