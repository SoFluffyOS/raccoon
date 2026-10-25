#pragma once
// macOS: the ring's IOSurfaces handed to the host by Mach port, so they need
// not be global (readable by any process that guesses an ID). A Unix socket
// cannot carry Mach ports, so the runner checks in a Mach service of its own,
// dev.raccoon.runner.<pid>, and names it, with a token, on the GPU socket;
// only that socket's client learns the token, and only a request carrying it
// gets ports. The rings stop being global only once such a request has come,
// so a client that cannot reach the service still finds them by ID. One
// thread answers.
//
// Messages, kept in sync with raccoon_view's RaccoonViewPlugin.mm:
//   request: msgh_id 'RPRT', a send-once reply port, then the ring's
//            generation (32 bits) and the 16-byte token;
//   reply:   msgh_id 'RPRY', complex, one port descriptor (a send right) per
//            surface in index order, none when refused, then the generation.
#if defined(__APPLE__)
#include <mach/mach.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace raccoon {

class SurfacePortServer {
 public:
  // Send rights to |client|'s ring |generation|'s surfaces, for the server
  // to pass on; false when that ring is gone. Called on the server's thread.
  using Lookup =
      std::function<bool(uint64_t client, uint32_t generation, std::vector<uint32_t>* ports)>;

  static constexpr mach_msg_id_t kRequestId = 0x52505254;  // 'RPRT'
  static constexpr mach_msg_id_t kReplyId = 0x52505259;    // 'RPRY'
  static constexpr mach_msg_id_t kWakeId = 0x5257414b;     // 'RWAK', its own
  static constexpr size_t kTokenSize = 16;

  SurfacePortServer() = default;
  ~SurfacePortServer();
  SurfacePortServer(const SurfacePortServer&) = delete;
  SurfacePortServer& operator=(const SurfacePortServer&) = delete;

  // Checks the service in and starts answering. False, with why, when the
  // name cannot be had.
  bool Start(Lookup lookup, std::string* error);
  bool started() const { return port_ != MACH_PORT_NULL; }

  const std::string& name() const { return name_; }
  // A new token for |client|, which from now on is the only one that gets
  // its ports: each GPU socket client is given its own, so a request from
  // one that has gone gets nothing. A runner showing several views has a
  // client each (#182).
  std::array<uint8_t, kTokenSize> RenewToken(uint64_t client);
  // |client|'s token gets nothing from now on.
  void ForgetToken(uint64_t client);

 private:
  void Serve();
  // Replies to |request|; its reply right is used up when the reply goes.
  void Answer(mach_msg_header_t* request);

  Lookup lookup_;
  std::string name_;
  std::mutex token_mutex_;
  std::map<uint64_t, std::array<uint8_t, kTokenSize>> tokens_;
  mach_port_t port_ = MACH_PORT_NULL;
  std::atomic<bool> stop_{false};
  // The serving thread has left its loop: a wake message would go unread.
  std::atomic<bool> exited_{false};
  std::thread thread_;
};

}  // namespace raccoon
#endif  // __APPLE__
