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
  if (thread_.joinable()) thread_.join();
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
    // A timeout, so a stop is noticed without destroying the port under
    // the receive.
    const mach_msg_return_t received =
        mach_msg(&buffer.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(buffer), port_, 250,
                 MACH_PORT_NULL);
    if (received == MACH_RCV_TIMED_OUT) continue;
    if (received != MACH_MSG_SUCCESS) continue;
    Answer(&buffer.header);
    // Whatever the request carried that was not used.
    mach_msg_destroy(&buffer.header);
  }
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
    if (std::memcmp(body->token, token_, kTokenSize) == 0) {
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
