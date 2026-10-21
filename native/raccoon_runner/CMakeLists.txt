cmake_minimum_required(VERSION 3.24)
project(raccoon_runner CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# The runtime directory for the engine revision in use: flutter_embedder.h
# next to libflutter_engine.so on Linux, FlutterEmbedder.framework on macOS.
# The engine library itself is loaded at run time with --engine-dir, so one
# runner binary serves several runtimes.
set(RACCOON_ENGINE_DIR "" CACHE PATH "Runtime directory with the embedder header")
if(NOT RACCOON_ENGINE_DIR)
  message(FATAL_ERROR "Set -DRACCOON_ENGINE_DIR to a runtime directory (see tool/engine_dir.sh)")
endif()
find_file(RACCOON_EMBEDDER_HEADER NAMES flutter_embedder.h
  PATHS ${RACCOON_ENGINE_DIR} NO_DEFAULT_PATH)
if(RACCOON_EMBEDDER_HEADER)
  set(RACCOON_EMBEDDER_INCLUDE_DIR ${RACCOON_ENGINE_DIR})
else()
  # The macOS framework names the header FlutterEmbedder.h; the sources keep
  # their one include and reach it through a generated alias.
  find_file(RACCOON_FRAMEWORK_HEADER NAMES FlutterEmbedder.h
    PATHS ${RACCOON_ENGINE_DIR}/FlutterEmbedder.framework/Headers NO_DEFAULT_PATH)
  if(NOT RACCOON_FRAMEWORK_HEADER)
    message(FATAL_ERROR "No flutter_embedder.h or FlutterEmbedder.framework in ${RACCOON_ENGINE_DIR} (see tool/engine_dir.sh)")
  endif()
  set(RACCOON_EMBEDDER_INCLUDE_DIR ${CMAKE_BINARY_DIR}/include)
  file(WRITE ${RACCOON_EMBEDDER_INCLUDE_DIR}/flutter_embedder.h
    "#include \"${RACCOON_FRAMEWORK_HEADER}\"\n")
endif()

# protoc for the C++ message code; tool/protoc.sh installs a user-local one.
set(RACCOON_PROTOC "$ENV{HOME}/.local/raccoon/protoc/bin/protoc" CACHE FILEPATH "protoc binary")

# protobuf-lite, built from source so the runner needs no system package. The
# version matches protoc 21.12.
include(FetchContent)
set(protobuf_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(protobuf_BUILD_PROTOC_BINARIES OFF CACHE BOOL "" FORCE)
set(protobuf_BUILD_LIBPROTOC OFF CACHE BOOL "" FORCE)
set(protobuf_WITH_ZLIB OFF CACHE BOOL "" FORCE)
set(protobuf_INSTALL OFF CACHE BOOL "" FORCE)
set(protobuf_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_POLICY_VERSION_MINIMUM 3.5)
FetchContent_Declare(protobuf
  URL https://github.com/protocolbuffers/protobuf/archive/refs/tags/v3.21.12.tar.gz
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(protobuf)

set(RACCOON_PROTO ${CMAKE_SOURCE_DIR}/proto/raccoon/v1/runner.proto)
set(RACCOON_GEN_DIR ${CMAKE_BINARY_DIR}/gen)
add_custom_command(
  OUTPUT ${RACCOON_GEN_DIR}/raccoon/v1/runner.pb.cc ${RACCOON_GEN_DIR}/raccoon/v1/runner.pb.h
  COMMAND ${CMAKE_COMMAND} -E make_directory ${RACCOON_GEN_DIR}
  COMMAND ${RACCOON_PROTOC} -I ${CMAKE_SOURCE_DIR}/proto --cpp_out=${RACCOON_GEN_DIR} ${RACCOON_PROTO}
  DEPENDS ${RACCOON_PROTO}
  COMMENT "protoc runner.proto"
)
add_library(raccoon_proto STATIC ${RACCOON_GEN_DIR}/raccoon/v1/runner.pb.cc)
target_include_directories(raccoon_proto PUBLIC ${RACCOON_GEN_DIR})
target_link_libraries(raccoon_proto PUBLIC libprotobuf-lite)

add_executable(raccoon_runner
  src/main.cc
  src/engine_host.cc
  src/engine_loader.cc
  src/event_loop.cc
  src/platform_task_runner.cc
  src/server.cc
  src/shared_buffers.cc
  src/software_frame.cc
  src/standard_codec.cc
  src/user_defaults_channels.cc
  src/window_channels.cc
)
target_include_directories(raccoon_runner PRIVATE ${RACCOON_EMBEDDER_INCLUDE_DIR} src)
target_compile_options(raccoon_runner PRIVATE -Wall -Wextra)
find_package(Threads REQUIRED)
target_link_libraries(raccoon_runner PRIVATE raccoon_proto ${CMAKE_DL_LIBS} Threads::Threads)
