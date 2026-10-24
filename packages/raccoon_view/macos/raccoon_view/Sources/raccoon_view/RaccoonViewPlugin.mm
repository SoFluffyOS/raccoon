// The host side of Raccoon's GPU buffers on macOS. Dart asks for a texture,
// names the runner's GPU socket, then names each frame's buffer; this side
// takes the runner's description of its ring from that socket, takes each
// IOSurface by Mach port (or looks it up by ID from a runner that does not
// hand out ports), wraps it as a pixel buffer, and hands Flutter the buffer
// of the latest frame whenever it asks.
//
// Surfaces by port: on connecting, this side sends 'RPRT'. A runner that
// can answers 'RSVC' with a Mach service name and a token, and builds its
// rings without global surfaces from then on; for each set, this side asks
// that service for the surfaces' ports. The messages are kept in sync with
// the runner's surface_port_server.h: request msgh_id 'RPRT' with a
// send-once reply port, the generation and the 16-byte token; reply msgh_id
// 'RPRY', one port descriptor per surface, none when refused.
//
// Channel raccoon_view/gpu: create() -> textureId; connect(textureId,
// socket) -> whether buffers go back from here; show(textureId, generation,
// index); dispose(textureId).
//
// No fence crosses the socket: the runner names a frame only once its GPU
// has drawn it, and a buffer goes back to the runner over the same socket
// once the next one is bound, by when the drawing that read it last was
// submitted a frame earlier.
#import "raccoon_view/RaccoonViewPlugin.h"

#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>

#include <fcntl.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

// One set of buffers as the runner described it, each surface looked up
// and wrapped; null where the lookup failed.
struct BufferSet {
  uint32_t generation = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<CVPixelBufferRef> buffers;

  ~BufferSet() {
    for (CVPixelBufferRef buffer : buffers) {
      if (buffer != nullptr) CVPixelBufferRelease(buffer);
    }
  }
};

uint32_t Read32(const uint8_t* at) {
  return static_cast<uint32_t>(at[0]) | (static_cast<uint32_t>(at[1]) << 8) |
         (static_cast<uint32_t>(at[2]) << 16) | (static_cast<uint32_t>(at[3]) << 24);
}

void Put32(uint8_t* at, uint32_t value) {
  for (int i = 0; i < 4; ++i) at[i] = static_cast<uint8_t>(value >> (8 * i));
}

constexpr mach_msg_id_t kPortRequestId = 0x52505254;  // 'RPRT'
constexpr mach_msg_id_t kPortReplyId = 0x52505259;    // 'RPRY'
constexpr size_t kTokenSize = 16;

// The runner's surface ports for ring |generation|, in index order; empty
// when it refused or did not answer.
std::vector<mach_port_t> AskPorts(mach_port_t service, uint32_t generation,
                                  const uint8_t* token) {
  mach_port_t reply = MACH_PORT_NULL;
  if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply) != KERN_SUCCESS) {
    return {};
  }
  struct Request {
    mach_msg_header_t header;
    uint32_t generation;
    uint8_t token[kTokenSize];
  };
  // One buffer for both: a send and receive in one call receives into the
  // buffer it sent from.
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
  message.request.header.msgh_id = kPortRequestId;
  message.request.generation = generation;
  std::memcpy(message.request.token, token, kTokenSize);
  std::vector<mach_port_t> ports;
  const mach_msg_return_t received =
      mach_msg(&message.header, MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT,
               sizeof(Request), sizeof(message), reply, 1000, MACH_PORT_NULL);
  if (received == MACH_MSG_SUCCESS && message.header.msgh_id == kPortReplyId &&
      (message.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0) {
    const auto* body = reinterpret_cast<const mach_msg_body_t*>(&message.header + 1);
    const auto* descriptors = reinterpret_cast<const mach_msg_port_descriptor_t*>(body + 1);
    for (mach_msg_size_t i = 0; i < body->msgh_descriptor_count; ++i) {
      ports.push_back(descriptors[i].name);
    }
  } else if (received == MACH_MSG_SUCCESS) {
    // Not the reply asked for: the rights it carried go (raccoon#127).
    mach_msg_destroy(&message.header);
  }
  mach_port_mod_refs(mach_task_self(), reply, MACH_PORT_RIGHT_RECEIVE, -1);
  return ports;
}

CVPixelBufferRef WrapSurfaceRef(IOSurfaceRef surface) {
  if (surface == nullptr) return nullptr;
  CVPixelBufferRef buffer = nullptr;
  // The pixel buffer keeps the surface.
  if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nullptr, &buffer) !=
      kCVReturnSuccess) {
    buffer = nullptr;
  }
  CFRelease(surface);
  return buffer;
}

// A global surface, by its ID: from a runner that does not hand out ports.
CVPixelBufferRef WrapSurface(uint32_t surface_id) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return WrapSurfaceRef(IOSurfaceLookup(surface_id));
#pragma clang diagnostic pop
}

// A surface by its port; the port's send right is used up.
CVPixelBufferRef WrapSurfacePort(mach_port_t port) {
  IOSurfaceRef surface = IOSurfaceLookupFromMachPort(port);
  mach_port_deallocate(mach_task_self(), port);
  return WrapSurfaceRef(surface);
}

}  // namespace

// ---- The texture ---------------------------------------------------------

@interface RaccoonGpuTexture : NSObject <FlutterTexture>
- (BOOL)connectToSocket:(NSString*)path;
- (void)showGeneration:(uint32_t)generation index:(int)index;
- (void)dispose;
@end

@implementation RaccoonGpuTexture {
  std::mutex _mutex;
  // The set waiting to be shown, and the one shown; the raster thread takes
  // pending over when Flutter asks for a buffer.
  std::unique_ptr<BufferSet> _pending;
  std::unique_ptr<BufferSet> _current;
  uint32_t _shownGeneration;
  int _shownIndex;
  // The buffer handed to Flutter last, -1 for none: given back once another
  // is.
  uint32_t _boundGeneration;
  int _boundIndex;
  // That buffer, retained: shown again while the frame named is not of the
  // set at hand, rather than one of the set's buffers nobody named.
  CVPixelBufferRef _boundBuffer;
  // The socket's reading state, on the main queue.
  int _socket;
  dispatch_source_t _reader;
  std::vector<uint8_t> _inbox;
  // The runner's surface port service and its token, once it answered
  // 'RPRT'; main queue.
  mach_port_t _service;
  uint8_t _token[kTokenSize];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _shownGeneration = 0;
    _shownIndex = -1;
    _boundGeneration = 0;
    _boundIndex = -1;
    _boundBuffer = nullptr;
    _socket = -1;
    _reader = nil;
    _service = MACH_PORT_NULL;
  }
  return self;
}

// Gives buffer |index| of |generation| back to the runner: 'RREL',
// generation, index, fenced (0: nothing rides along). Mutex held.
- (void)sendRelease:(uint32_t)generation index:(int)index {
  if (_socket < 0) return;
  uint8_t message[4 + 16] = {16, 0, 0, 0, 'R', 'R', 'E', 'L'};
  Put32(message + 8, generation);
  Put32(message + 12, static_cast<uint32_t>(index));
  Put32(message + 16, 0);
  send(_socket, message, sizeof(message), 0);
}

- (CVPixelBufferRef)copyPixelBuffer {
  std::lock_guard<std::mutex> lock(_mutex);
  if (_pending) _current = std::move(_pending);
  if (!_current || _current->buffers.empty()) return nullptr;
  const BufferSet& set = *_current;
  // The frame named is not of this set: the ring changed on one socket and
  // the names on the other. Buffer 0 of a new ring may be the one being
  // drawn, or never drawn, and of an old ring stale; the frame shown last
  // stays until one of this set is named (raccoon#127).
  if (_shownGeneration != set.generation || _shownIndex < 0 ||
      static_cast<size_t>(_shownIndex) >= set.buffers.size() ||
      set.buffers[_shownIndex] == nullptr) {
    return _boundBuffer == nullptr ? nullptr : CVPixelBufferRetain(_boundBuffer);
  }
  const bool rebound = _boundIndex != _shownIndex || _boundGeneration != set.generation;
  const uint32_t beforeGeneration = _boundGeneration;
  const int beforeIndex = _boundIndex;
  _boundGeneration = set.generation;
  _boundIndex = _shownIndex;
  CVPixelBufferRef buffer = set.buffers[_shownIndex];
  if (buffer != _boundBuffer) {
    if (_boundBuffer != nullptr) CVPixelBufferRelease(_boundBuffer);
    _boundBuffer = CVPixelBufferRetain(buffer);
  }
  // The buffer bound before was last read by the frame drawn before this
  // one: the runner's again.
  if (rebound && beforeIndex >= 0) [self sendRelease:beforeGeneration index:beforeIndex];
  return CVPixelBufferRetain(buffer);
}

- (void)showGeneration:(uint32_t)generation index:(int)index {
  std::lock_guard<std::mutex> lock(_mutex);
  // A frame named but never bound (the raster thread did not get to it)
  // was never read: the runner's again at once.
  const bool superseded =
      _shownIndex >= 0 && (_shownIndex != index || _shownGeneration != generation);
  const bool unbound =
      _shownIndex != _boundIndex || _shownGeneration != _boundGeneration;
  if (superseded && unbound) [self sendRelease:_shownGeneration index:_shownIndex];
  _shownGeneration = generation;
  _shownIndex = index;
}

// ---- The GPU socket ------------------------------------------------------

// Parses the framed sets in the inbox: 'RGPU', generation, count, width,
// height, fourcc, modifier (64 bits), count pairs of stride and offset,
// then count IOSurface IDs. Main queue.
- (void)parseInbox {
  size_t offset = 0;
  while (_inbox.size() - offset >= 4) {
    const uint32_t length = Read32(_inbox.data() + offset);
    if (_inbox.size() - offset - 4 < length) break;
    const uint8_t* payload = _inbox.data() + offset + 4;
    offset += 4 + length;
    if (length >= 8 && std::memcmp(payload, "RSVC", 4) == 0) {
      [self takeService:payload length:length];
      continue;
    }
    if (length < 32 || std::memcmp(payload, "RGPU", 4) != 0) continue;
    const uint32_t count = Read32(payload + 8);
    // Not whole, or no IDs; in 64 bits, so a bad count can't wrap it.
    if (length < 32 + static_cast<uint64_t>(count) * 12) continue;
    auto set = std::make_unique<BufferSet>();
    set->generation = Read32(payload + 4);
    set->width = Read32(payload + 12);
    set->height = Read32(payload + 16);
    // By port when the runner hands them out; by ID otherwise, or when the
    // service did not answer for this set.
    std::vector<mach_port_t> ports;
    if (_service != MACH_PORT_NULL) ports = AskPorts(_service, set->generation, _token);
    const uint8_t* ids = payload + 32 + count * 8;
    for (uint32_t i = 0; i < count; ++i) {
      set->buffers.push_back(ports.size() == count ? WrapSurfacePort(ports[i])
                                                   : WrapSurface(Read32(ids + i * 4)));
    }
    if (ports.size() != count) {
      for (mach_port_t port : ports) mach_port_deallocate(mach_task_self(), port);
    }
    if (std::getenv("RACCOON_TRACE") != nullptr) {
      std::fprintf(stderr, "raccoon_view: ring %u, %u surfaces %s\n", set->generation, count,
                   ports.size() == count ? "by port" : "by ID");
    }
    std::lock_guard<std::mutex> lock(_mutex);
    _pending = std::move(set);
  }
  _inbox.erase(_inbox.begin(), _inbox.begin() + offset);
}

// 'RSVC', the length of the service's name, the name, the 16-byte token.
// Main queue.
- (void)takeService:(const uint8_t*)payload length:(uint32_t)length {
  const uint32_t size = Read32(payload + 4);
  if (length < 8 + static_cast<uint64_t>(size) + kTokenSize) return;
  const std::string name(reinterpret_cast<const char*>(payload + 8), size);
  mach_port_t service = MACH_PORT_NULL;
  if (bootstrap_look_up(bootstrap_port, name.c_str(), &service) != KERN_SUCCESS) return;
  if (_service != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), _service);
  _service = service;
  std::memcpy(_token, payload + 8 + size, kTokenSize);
}

- (void)readSocket {
  uint8_t buffer[16 * 1024];
  const ssize_t got = recv(_socket, buffer, sizeof(buffer), 0);
  if (got <= 0) {
    // The runner hung up: nothing more comes, and releases have nowhere
    // to go.
    [self closeSocket];
    return;
  }
  _inbox.insert(_inbox.end(), buffer, buffer + got);
  [self parseInbox];
}

- (void)closeSocket {
  if (_reader != nil) {
    // Cancelling closes the descriptor, from the cancel handler.
    dispatch_source_cancel(_reader);
    _reader = nil;
  }
  std::lock_guard<std::mutex> lock(_mutex);
  _socket = -1;
}

- (BOOL)connectToSocket:(NSString*)path {
  const char* name = path.UTF8String;
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (name == nullptr || std::strlen(name) >= sizeof(address.sun_path)) return NO;
  std::strcpy(address.sun_path, name);
  const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return NO;
  const int noSigpipe = 1;
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 ||
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, sizeof(noSigpipe)) != 0 ||
      connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
    close(fd);
    return NO;
  }
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _socket = fd;
  }
  _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, static_cast<uintptr_t>(fd), 0,
                                   dispatch_get_main_queue());
  dispatch_source_set_event_handler(_reader, ^{
    [self readSocket];
  });
  dispatch_source_set_cancel_handler(_reader, ^{
    close(fd);
  });
  dispatch_resume(_reader);
  // Surfaces by Mach port, please: a runner that cannot ignores this.
  const uint8_t ask[] = {4, 0, 0, 0, 'R', 'P', 'R', 'T'};
  send(fd, ask, sizeof(ask), 0);
  return YES;
}

- (void)dispose {
  [self closeSocket];
  if (_service != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), _service);
    _service = MACH_PORT_NULL;
  }
  std::lock_guard<std::mutex> lock(_mutex);
  _pending.reset();
  _current.reset();
  if (_boundBuffer != nullptr) {
    CVPixelBufferRelease(_boundBuffer);
    _boundBuffer = nullptr;
  }
}

@end

// ---- The plugin ----------------------------------------------------------

@implementation RaccoonViewPlugin {
  id<FlutterTextureRegistry> _registry;
  NSMutableDictionary<NSNumber*, RaccoonGpuTexture*>* _textures;
}

+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:@"raccoon_view/gpu"
                                  binaryMessenger:registrar.messenger];
  RaccoonViewPlugin* plugin = [[RaccoonViewPlugin alloc] initWithRegistry:registrar.textures];
  [registrar addMethodCallDelegate:plugin channel:channel];
}

- (instancetype)initWithRegistry:(id<FlutterTextureRegistry>)registry {
  self = [super init];
  if (self) {
    _registry = registry;
    _textures = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"create"]) {
    RaccoonGpuTexture* texture = [[RaccoonGpuTexture alloc] init];
    const int64_t textureId = [_registry registerTexture:texture];
    _textures[@(textureId)] = texture;
    result(@(textureId));
    return;
  }
  NSDictionary* arguments =
      [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
  NSNumber* textureId = arguments[@"textureId"];
  RaccoonGpuTexture* texture = textureId == nil ? nil : _textures[textureId];
  if (texture == nil) {
    result([FlutterError errorWithCode:@"unknown" message:@"no such texture" details:nil]);
    return;
  }
  if ([call.method isEqualToString:@"connect"]) {
    NSString* socket = arguments[@"socket"];
    if (![socket isKindOfClass:[NSString class]] || ![texture connectToSocket:socket]) {
      result([FlutterError errorWithCode:@"connect"
                                 message:@"could not connect to the GPU socket"
                                 details:nil]);
      return;
    }
    // Buffers go back from here, once drawn.
    result(@YES);
    return;
  }
  if ([call.method isEqualToString:@"show"]) {
    [texture showGeneration:[arguments[@"generation"] unsignedIntValue]
                      index:[arguments[@"index"] intValue]];
    [_registry textureFrameAvailable:textureId.longLongValue];
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"dispose"]) {
    [_registry unregisterTexture:textureId.longLongValue];
    [texture dispose];
    [_textures removeObjectForKey:textureId];
    result(nil);
    return;
  }
  result(FlutterMethodNotImplemented);
}

@end
