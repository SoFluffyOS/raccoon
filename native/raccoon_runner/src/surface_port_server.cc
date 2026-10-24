#if defined(__APPLE__)
#include "surface_port_server.h"

#include <servers/bootstrap.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>

namespace raccoon {

namespace {

// The most surfaces one reply carries; the ring has four.
constexpr size_t kMaxPorts = 16;

struct Request {
  mach_msg_header_t header;
  uint32_t generation;
  uint8_t token[SurfacePortServer::kTokenSize];
};

struct Reply {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t ports[kMaxPorts];
  // The generation follows the last descriptor sent, not this array's end;
  // with every descriptor sent, it lands here (#125).
  uint32_t generation_room;
};

}  // namespace

SurfacePortServer::~SurfacePortServer() {
  stop_ = true;
  if (thread_.joinable()) {
    // A message of its own wakes the receive, which waits with no timeout.
    // Sent again while the queue is full: the thread is draining it.
    mach_msg_header_t wake{};
    wake.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND, 0);
    wake.msgh_size = sizeof(wake);
    wake.msgh_remote_port = port_;
    wake.msgh_id = kWakeId;
    while (!exited_ && mach_msg(&wake, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(wake), 0,
                                MACH_PORT_NULL, 100, MACH_PORT_NULL) == MACH_SEND_TIMED_OUT) {
    }
    thread_.join();
  }
  if (port_ != MACH_PORT_NULL) {
    mach_port_mod_refs(mach_task_self(), port_, MACH_PORT_RIGHT_RECEIVE, -1);
  }
}

bool SurfacePortServer::Start(Lookup lookup, std::string* error) {
  if (started()) return true;
  name_ = "dev.raccoon.runner." + std::to_string(getpid());
  mach_port_t port = MACH_PORT_NULL;
  const kern_return_t result = bootstrap_check_in(bootstrap_port, name_.c_str(), &port);
  if (result != KERN_SUCCESS) {
    *error = std::string("bootstrap_check_in ") + name_ + ": " + bootstrap_strerror(result);
    return false;
  }
  arc4random_buf(token_, sizeof(token_));
  lookup_ = std::move(lookup);
  port_ = port;
  thread_ = std::thread([this] { Serve(); });
  return true;
}

std::array<uint8_t, SurfacePortServer::kTokenSize> SurfacePortServer::RenewToken() {
  std::array<uint8_t, kTokenSize> token;
  arc4random_buf(token.data(), token.size());
  std::lock_guard<std::mutex> lock(token_mutex_);
  std::memcpy(token_, token.data(), token.size());
  return token;
}

void SurfacePortServer::Serve() {
  // Room for a request and the largest trailer the kernel adds.
  union {
    mach_msg_header_t header;
    uint8_t bytes[sizeof(Request) + MAX_TRAILER_SIZE];
  } buffer;
  while (!stop_) {
    std::memset(&buffer, 0, sizeof(buffer));
    buffer.header.msgh_size = sizeof(buffer);
    buffer.header.msgh_local_port = port_;
    // No timeout, so an idle runner sleeps here; the destructor's wake
    // message ends it.
    const mach_msg_return_t received = mach_msg(&buffer.header, MACH_RCV_MSG, 0, sizeof(buffer),
                                                port_, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if (received == MACH_RCV_INVALID_NAME || received == MACH_RCV_PORT_DIED) break;
    if (received != MACH_MSG_SUCCESS) continue;
    if (buffer.header.msgh_id != kWakeId) Answer(&buffer.header);
    // Whatever the request carried that was not used.
    mach_msg_destroy(&buffer.header);
  }
  exited_ = true;
}

void SurfacePortServer::Answer(mach_msg_header_t* request) {
  const mach_port_t reply_port = request->msgh_remote_port;
  if (reply_port == MACH_PORT_NULL) return;
  std::vector<uint32_t> ports;
  uint32_t generation = 0;
  if (request->msgh_id == kRequestId && request->msgh_size >= sizeof(Request)) {
    const auto* body = reinterpret_cast<const Request*>(request);
    generation = body->generation;
    // Only the GPU socket's client knows the token; anyone else gets none.
    bool known;
    {
      std::lock_guard<std::mutex> lock(token_mutex_);
      known = std::memcmp(body->token, token_, kTokenSize) == 0;
    }
    if (known) {
      if (!lookup_(generation, &ports) || ports.size() > kMaxPorts) {
        for (uint32_t port : ports) mach_port_deallocate(mach_task_self(), port);
        ports.clear();
      }
    }
  }
  Reply reply{};
  const size_t descriptors = sizeof(mach_msg_port_descriptor_t) * ports.size();
  reply.header.msgh_bits =
      MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(request->msgh_bits), 0) | MACH_MSGH_BITS_COMPLEX;
  reply.header.msgh_remote_port = reply_port;
  reply.header.msgh_local_port = MACH_PORT_NULL;
  reply.header.msgh_id = kReplyId;
  reply.body.msgh_descriptor_count = static_cast<mach_msg_size_t>(ports.size());
  for (size_t i = 0; i < ports.size(); ++i) {
    reply.ports[i].name = ports[i];
    reply.ports[i].disposition = MACH_MSG_TYPE_MOVE_SEND;
    reply.ports[i].type = MACH_MSG_PORT_DESCRIPTOR;
  }
  auto* tail = reinterpret_cast<uint8_t*>(&reply.ports[0]) + descriptors;
  std::memcpy(tail, &generation, sizeof(generation));
  reply.header.msgh_size = static_cast<mach_msg_size_t>(sizeof(mach_msg_header_t) +
                                                        sizeof(mach_msg_body_t) + descriptors +
                                                        sizeof(generation));
  const mach_msg_return_t sent = mach_msg(&reply.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                          reply.header.msgh_size, 0, MACH_PORT_NULL, 250,
                                          MACH_PORT_NULL);
  if (sent != MACH_MSG_SUCCESS) {
    // The rights did not move: they are still ours to let go, and the reply
    // right goes with the request.
    for (uint32_t port : ports) mach_port_deallocate(mach_task_self(), port);
    return;
  }
  // The reply right went with the reply: not the request's to destroy.
  request->msgh_remote_port = MACH_PORT_NULL;
  request->msgh_bits &= ~MACH_MSGH_BITS_REMOTE_MASK;
}

}  // namespace raccoon
#endif  // __APPLE__
