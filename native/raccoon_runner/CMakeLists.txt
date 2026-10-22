cmake_minimum_required(VERSION 3.24)
project(raccoon_runner CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# On Windows the C runtime is linked in, protobuf's too, so a prebuilt runner
# needs no Visual C++ redistributable.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

# The runner's version, one line in VERSION: what --version prints, what the
# release archives are named after (tool/package.sh), and what the Simulator
# matches a prebuilt runner against. Semantic versioning; a -pre.N suffix
# marks a prerelease.
file(READ ${CMAKE_SOURCE_DIR}/VERSION RACCOON_RUNNER_VERSION)
string(STRIP "${RACCOON_RUNNER_VERSION}" RACCOON_RUNNER_VERSION)

# The runtime directory for the engine revision in use: flutter_embedder.h
# next to libflutter_engine.so on Linux and flutter_engine.dll on Windows,
# FlutterEmbedder.framework on macOS.
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
if(WIN32)
  file(TO_CMAKE_PATH "$ENV{USERPROFILE}/.local/raccoon/protoc/bin/protoc.exe" RACCOON_PROTOC_DEFAULT)
else()
  set(RACCOON_PROTOC_DEFAULT "$ENV{HOME}/.local/raccoon/protoc/bin/protoc")
endif()
set(RACCOON_PROTOC "${RACCOON_PROTOC_DEFAULT}" CACHE FILEPATH "protoc binary")

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

# JSON for the channels the framework speaks JSON on (text input, key events).
set(JSON_BuildTests OFF CACHE INTERNAL "")
FetchContent_Declare(json
  URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(json)

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
  src/glib_pump.cc
  src/plugins.cc
  src/plugins_linux.cc
  src/platform_task_runner.cc
  src/server.cc
  src/shared_buffers.cc
  src/software_frame.cc
  src/stderr_capture.cc
  src/standard_codec.cc
  src/text_input.cc
  src/user_defaults_channels.cc
  src/win_sockets.cc
  src/window_channels.cc
)
target_include_directories(raccoon_runner PRIVATE ${RACCOON_EMBEDDER_INCLUDE_DIR} src)
target_compile_definitions(raccoon_runner PRIVATE RACCOON_RUNNER_VERSION="${RACCOON_RUNNER_VERSION}")
if(MSVC)
  target_compile_options(raccoon_runner PRIVATE /W3 /utf-8)
  # The POSIX names the C runtime keeps (close, strerror, getenv) without
  # their deprecation warnings, and windows.h without min and max.
  target_compile_definitions(raccoon_runner PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE)
else()
  target_compile_options(raccoon_runner PRIVATE -Wall -Wextra)
endif()
find_package(Threads REQUIRED)
target_link_libraries(raccoon_runner PRIVATE raccoon_proto ${CMAKE_DL_LIBS} Threads::Threads)
target_link_libraries(raccoon_runner PRIVATE nlohmann_json::nlohmann_json)
if(WIN32)
  target_link_libraries(raccoon_runner PRIVATE ws2_32)
endif()

# The GPU renderer, one per host; without it the runner rasterizes in
# software. On macOS, Metal, with the ring of buffers backed by IOSurfaces.
# Elsewhere, EGL without a window and GLES 2 (Mesa on Linux), when
# pkg-config finds them, and the plugin library beside it.
if(APPLE)
  enable_language(OBJCXX)
  target_sources(raccoon_runner PRIVATE src/metal_renderer.mm)
  set_target_properties(raccoon_runner PROPERTIES
    OBJCXX_STANDARD 17 OBJCXX_STANDARD_REQUIRED ON)
  set_source_files_properties(src/metal_renderer.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_compile_definitions(raccoon_runner PRIVATE RACCOON_HAS_METAL=1)
  target_link_libraries(raccoon_runner PRIVATE
    "-framework Metal" "-framework IOSurface" "-framework Foundation")
  message(STATUS "Metal renderer: on")
  # Native plugins: the protocols of FlutterMacOS.framework, implemented here
  # from its headers alone (third_party/flutter_macos); the framework itself
  # is opened at run time from the Flutter SDK, before the plugins.
  target_sources(raccoon_runner PRIVATE src/plugins_mac.mm src/run_loop_pump.mm)
  set_source_files_properties(src/plugins_mac.mm src/run_loop_pump.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(raccoon_runner PRIVATE ${CMAKE_SOURCE_DIR}/third_party/flutter_macos)
  target_compile_definitions(raccoon_runner PRIVATE RACCOON_HAS_PLUGINS=1)
  target_link_libraries(raccoon_runner PRIVATE
    "-framework AppKit" "-framework CoreVideo")
  message(STATUS "Native plugins: on")
  # example/plugins/echo as the framework a plugin pod builds, linked against
  # the SDK's FlutterMacOS as plugins are; the tests load it. Needs the SDK's
  # macOS artifacts (flutter precache --macos).
  find_program(RACCOON_FLUTTER flutter)
  if(RACCOON_FLUTTER)
    get_filename_component(RACCOON_FLUTTER_REAL ${RACCOON_FLUTTER} REALPATH)
    get_filename_component(RACCOON_SDK ${RACCOON_FLUTTER_REAL} DIRECTORY)
    get_filename_component(RACCOON_SDK ${RACCOON_SDK} DIRECTORY)
    set(RACCOON_FLUTTER_MACOS_DIR
      ${RACCOON_SDK}/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64)
  endif()
  if(RACCOON_FLUTTER_MACOS_DIR AND EXISTS ${RACCOON_FLUTTER_MACOS_DIR}/FlutterMacOS.framework)
    enable_language(OBJC)
    add_library(raccoon_echo SHARED
      example/plugins/echo/macos/Classes/RaccoonEchoPlugin.m)
    set_target_properties(raccoon_echo PROPERTIES
      FRAMEWORK TRUE
      INSTALL_NAME_DIR "@rpath"
      LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/example_plugins/echo)
    target_compile_options(raccoon_echo PRIVATE -fobjc-arc -F${RACCOON_FLUTTER_MACOS_DIR})
    target_link_options(raccoon_echo PRIVATE -F${RACCOON_FLUTTER_MACOS_DIR})
    target_link_libraries(raccoon_echo PRIVATE
      "-framework FlutterMacOS" "-framework Foundation" "-framework CoreVideo")
  else()
    message(STATUS "No FlutterMacOS.framework in the SDK cache: example plugin skipped")
  endif()
elseif(WIN32)
  # Software rendering, frames inline. D3D11 shared textures and native
  # plugins come later (raccoon#25, raccoon#36).
  message(STATUS "GPU renderer: off (not on Windows yet)")
  message(STATUS "Native plugins: off (not on Windows yet)")
else()
  find_package(PkgConfig QUIET)
  if(PkgConfig_FOUND)
    pkg_check_modules(RACCOON_GL IMPORTED_TARGET egl glesv2)
    # The plugin-facing half of Flutter's Linux embedding, as a library of the
    # same soname plugin binaries link against (third_party/flutter_linux).
    pkg_check_modules(RACCOON_FL IMPORTED_TARGET glib-2.0 gobject-2.0 gio-2.0 gmodule-2.0 gtk+-3.0 epoxy)
    if(RACCOON_FL_FOUND)
      file(GLOB RACCOON_FL_SOURCES
           ${CMAKE_SOURCE_DIR}/third_party/flutter_linux/flutter/shell/platform/linux/*.cc)
      add_library(flutter_linux_gtk SHARED
        ${RACCOON_FL_SOURCES}
        third_party/flutter_linux/raccoon/fl_engine.cc
        third_party/flutter_linux/raccoon/fl_view.cc)
      set_target_properties(flutter_linux_gtk PROPERTIES
        OUTPUT_NAME flutter_linux_gtk
        CXX_VISIBILITY_PRESET default)
      target_include_directories(flutter_linux_gtk
        PUBLIC ${CMAKE_SOURCE_DIR}/third_party/flutter_linux
        PRIVATE ${RACCOON_EMBEDDER_INCLUDE_DIR})
      target_compile_options(flutter_linux_gtk PRIVATE -w)
      # The public headers refuse direct inclusion unless the library itself
      # is being built; the JSON codecs read and write with RapidJSON.
      target_compile_definitions(flutter_linux_gtk PRIVATE FLUTTER_LINUX_COMPILATION)
      FetchContent_Declare(rapidjson
        URL https://github.com/Tencent/rapidjson/archive/refs/tags/v1.1.0.tar.gz
        URL_HASH SHA256=bf7ced29704a1e696fbccf2a2b4ea068e7774fa37f6d7dd4039d0787f8bed98e)
      set(RAPIDJSON_BUILD_DOC OFF CACHE BOOL "" FORCE)
      set(RAPIDJSON_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
      set(RAPIDJSON_BUILD_TESTS OFF CACHE BOOL "" FORCE)
      FetchContent_MakeAvailable(rapidjson)
      target_include_directories(flutter_linux_gtk PRIVATE ${rapidjson_SOURCE_DIR}/include)
      target_link_libraries(flutter_linux_gtk PUBLIC PkgConfig::RACCOON_FL)
      target_link_libraries(raccoon_runner PRIVATE flutter_linux_gtk)
      # The runner uses the library's private headers, as the embedding's own
      # engine would.
      target_compile_definitions(raccoon_runner PRIVATE RACCOON_HAS_PLUGINS=1 FLUTTER_LINUX_COMPILATION)
      set_target_properties(raccoon_runner PROPERTIES BUILD_RPATH "$ORIGIN" INSTALL_RPATH "$ORIGIN")
      # What Flutter's desktop template gives a plugin, so one builds here as
      # it does there; example/plugins/echo proves it and the tests load it.
      function(APPLY_STANDARD_SETTINGS TARGET)
        target_compile_features(${TARGET} PUBLIC cxx_std_14)
        target_compile_options(${TARGET} PRIVATE -Wall -Werror)
      endfunction()
      pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
      add_library(flutter INTERFACE)
      target_include_directories(flutter INTERFACE
        ${CMAKE_SOURCE_DIR}/third_party/flutter_linux/flutter/shell/platform/linux/public)
      target_link_libraries(flutter INTERFACE flutter_linux_gtk PkgConfig::GTK)
      add_subdirectory(example/plugins/echo/linux example_plugins/echo)
    else()
      message(STATUS "GLib, GTK or epoxy headers missing: no native plugins")
    endif()
  endif()
  if(RACCOON_GL_FOUND)
    target_sources(raccoon_runner PRIVATE src/gl_renderer.cc)
    target_compile_definitions(raccoon_runner PRIVATE RACCOON_HAS_GL=1)
    target_link_libraries(raccoon_runner PRIVATE PkgConfig::RACCOON_GL)
    message(STATUS "GL renderer: on (EGL ${RACCOON_GL_egl_VERSION})")
  else()
    message(STATUS "GL renderer: off (no egl and glesv2 for pkg-config)")
  endif()
endif()
