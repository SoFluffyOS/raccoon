cmake_minimum_required(VERSION 3.24)
# The oldest macOS the Flutter engine it loads runs on, not the build
# host's: a prebuilt runner from a newer CI image would refuse to load on
# an older Mac. Before project(), which reads it.
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "Oldest macOS the runner runs on")
project(raccoon_runner CXX)

# Optimised, with symbols, unless a type is given: a checkout's runner is the
# one tool/raccoon-device runs, and unoptimised its pixel path costs four
# times the CPU. The runner uses no assert, so nothing is lost.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# On Windows the C runtime is linked in, protobuf's too, so a prebuilt runner
# needs no Visual C++ redistributable.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
# Only what is called gets linked: protobuf-lite and nlohmann bring much the
# runner never calls (#110). Mach-O drops it by symbol on its own; ELF needs
# a section per function and per datum first. MSVC's Release link already
# drops unreferenced code (/OPT:REF).
if(APPLE)
  add_link_options(-Wl,-dead_strip)
elseif(UNIX)
  add_compile_options(-ffunction-sections -fdata-sections)
  add_link_options(-Wl,--gc-sections)
endif()
# Link-time optimisation, but for Debug: 66 KB off the release runner on
# macOS, 7%, at no measurable CPU, and the tests run what ships. Set before
# protobuf and json are fetched, so they get it too.
# Per configuration, so a multi-config generator (Visual Studio, Xcode)
# leaves Debug alone too.
include(CheckIPOSupported)
check_ipo_supported(RESULT RACCOON_IPO LANGUAGES CXX)
if(RACCOON_IPO)
  set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE ON)
  set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELWITHDEBINFO ON)
  set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_MINSIZEREL ON)
endif()

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
  src/camera_channels.cc
  src/camera_source.cc
  src/engine_host.cc
  src/key_codes.cc
  src/engine_loader.cc
  src/event_loop.cc
  src/host_settings.cc
  src/host_settings_win.cc
  src/jpeg_encoder.cc
  src/glib_pump.cc
  src/plugins.cc
  src/plugins_linux.cc
  src/platform_task_runner.cc
  src/secure_storage_options.cc
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
target_include_directories(raccoon_runner SYSTEM PRIVATE third_party/stb)
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

# The channels the runner answers itself, fed random input: run by the
# runtime's integration tests on every host, not shipped.
add_executable(raccoon_channels_check
  test/channels_check.cc
  src/secure_storage_options.cc
  src/standard_codec.cc
  src/text_input.cc
  src/user_defaults_channels.cc
  src/window_channels.cc
)
target_include_directories(raccoon_channels_check PRIVATE src)
target_link_libraries(raccoon_channels_check PRIVATE nlohmann_json::nlohmann_json)
# The runner's warnings, so the check is held to its sources' standard.
if(MSVC)
  target_compile_options(raccoon_channels_check PRIVATE /W3 /utf-8)
  target_compile_definitions(raccoon_channels_check PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE)
else()
  target_compile_options(raccoon_channels_check PRIVATE -Wall -Wextra)
endif()
if(WIN32)
  target_link_libraries(raccoon_runner PRIVATE ws2_32 winmm)
  # A video as the camera's source, and its recordings, by Media
  # Foundation; and the tool the tests make a video with.
  target_sources(raccoon_runner PRIVATE src/camera_video_win.cc src/camera_recorder_win.cc)
  target_link_libraries(raccoon_runner PRIVATE mfplat mfreadwrite mfuuid ole32)
  # Loaded when first called, not at start: most runs never touch them, and
  # an N edition has no Media Foundation (#224).
  if(MSVC)
    target_link_options(raccoon_runner PRIVATE
      /DELAYLOAD:mfplat.dll /DELAYLOAD:mfreadwrite.dll)
    target_link_libraries(raccoon_runner PRIVATE delayimp)
  endif()
  add_executable(raccoon_test_video test/make_test_video.cc)
  target_compile_definitions(raccoon_test_video PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
  target_link_libraries(raccoon_test_video PRIVATE mfplat mfreadwrite mfuuid ole32)
endif()

# The GPU renderer, one per host; without it the runner rasterizes in
# software. On macOS, Metal, with the ring of buffers backed by IOSurfaces.
# Elsewhere, EGL without a window and GLES 2 (Mesa on Linux), when
# pkg-config finds them, and the plugin library beside it.
if(APPLE)
  enable_language(OBJCXX)
  target_sources(raccoon_runner PRIVATE src/metal_renderer.mm src/surface_port_server.cc)
  # A GPU socket client that takes the ring's surfaces by Mach port; the
  # runtime's tests run it against the runner.
  add_executable(raccoon_gpu_port_check test/gpu_port_check.mm)
  target_link_libraries(raccoon_gpu_port_check PRIVATE "-framework IOSurface" "-framework CoreFoundation")
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
  target_sources(raccoon_runner PRIVATE src/plugins_mac.mm src/run_loop_pump.mm
    src/host_settings_mac.mm)
  set_source_files_properties(src/plugins_mac.mm src/run_loop_pump.mm src/host_settings_mac.mm
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
      example/plugins/echo/macos/raccoon_echo/Sources/raccoon_echo/RaccoonEchoPlugin.m)
    set_target_properties(raccoon_echo PROPERTIES
      FRAMEWORK TRUE
      INSTALL_NAME_DIR "@rpath"
      LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/example_plugins/echo)
    target_compile_options(raccoon_echo PRIVATE -fobjc-arc -F${RACCOON_FLUTTER_MACOS_DIR})
    target_link_options(raccoon_echo PRIVATE -F${RACCOON_FLUTTER_MACOS_DIR})
    target_link_libraries(raccoon_echo PRIVATE
      "-framework FlutterMacOS" "-framework AppKit" "-framework CoreVideo")
  else()
    message(STATUS "No FlutterMacOS.framework in the SDK cache: example plugin skipped")
  endif()
elseif(WIN32)
  # The GPU renderer: Vulkan, the one the prebuilt Windows embedder offers,
  # frames read back; vulkan-1.dll is opened at run time, so only the
  # headers are needed here. Sharing the images with a client comes later
  # (raccoon#25).
  FetchContent_Declare(vulkan_headers
    URL https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.3.296.tar.gz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_MakeAvailable(vulkan_headers)
  target_sources(raccoon_runner PRIVATE src/vulkan_renderer.cc)
  target_compile_definitions(raccoon_runner PRIVATE RACCOON_HAS_VULKAN=1)
  target_link_libraries(raccoon_runner PRIVATE Vulkan::Headers d3d11 dxgi)
  # D3D11 only for a client that imports shared textures (#224).
  if(MSVC)
    target_link_options(raccoon_runner PRIVATE /DELAYLOAD:d3d11.dll)
  endif()
  message(STATUS "GPU renderer: on (Vulkan; shared D3D11 textures for a client that imports them)")
  # A GPU socket client that opens the ring's textures by their shared
  # handles and checks the frame in them; the tests run it.
  add_executable(raccoon_gpu_handle_check test/gpu_handle_check.cc)
  target_compile_definitions(raccoon_gpu_handle_check PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
  target_link_libraries(raccoon_gpu_handle_check PRIVATE ws2_32 d3d11)
  # Native plugins: the C API of Flutter's Windows embedding, implemented in
  # a flutter_windows.dll of the runner's own, beside it, from the vendored
  # headers (third_party/flutter_windows). Plugin DLLs import that name.
  add_library(flutter_windows SHARED src/flutter_windows/flutter_windows.cc)
  target_include_directories(flutter_windows PRIVATE
    ${CMAKE_SOURCE_DIR}/third_party/flutter_windows/include)
  target_compile_definitions(flutter_windows PRIVATE
    FLUTTER_DESKTOP_LIBRARY NOMINMAX WIN32_LEAN_AND_MEAN)
  target_compile_options(flutter_windows PRIVATE /W3 /utf-8)
  target_link_libraries(flutter_windows PRIVATE user32 shcore)
  target_sources(raccoon_runner PRIVATE src/plugins_windows.cc src/message_pump.cc)
  # A version resource, as every Windows program has one: package_info_plus
  # reads the running executable's, and throws without one.
  enable_language(RC)
  string(REGEX MATCH "^([0-9]+)\\.([0-9]+)\\.([0-9]+)" RACCOON_VERSION_NUMBERS
    "${RACCOON_RUNNER_VERSION}")
  set(RACCOON_VERSION_COMMAS "${CMAKE_MATCH_1},${CMAKE_MATCH_2},${CMAKE_MATCH_3},0")
  file(WRITE ${CMAKE_BINARY_DIR}/raccoon_runner.rc "#include <winver.h>
VS_VERSION_INFO VERSIONINFO
 FILEVERSION ${RACCOON_VERSION_COMMAS}
 PRODUCTVERSION ${RACCOON_VERSION_COMMAS}
 FILEOS VOS_NT_WINDOWS32
 FILETYPE VFT_APP
BEGIN
  BLOCK \"StringFileInfo\"
  BEGIN
    BLOCK \"040904e4\"
    BEGIN
      VALUE \"CompanyName\", \"SoFluffy\"
      VALUE \"FileDescription\", \"Raccoon runner\"
      VALUE \"FileVersion\", \"${RACCOON_RUNNER_VERSION}\"
      VALUE \"InternalName\", \"raccoon_runner\"
      VALUE \"OriginalFilename\", \"raccoon_runner.exe\"
      VALUE \"ProductName\", \"raccoon_runner\"
      VALUE \"ProductVersion\", \"${RACCOON_RUNNER_VERSION}\"
    END
  END
  BLOCK \"VarFileInfo\"
  BEGIN
    VALUE \"Translation\", 0x409, 1252
  END
END
")
  target_sources(raccoon_runner PRIVATE ${CMAKE_BINARY_DIR}/raccoon_runner.rc)
  # UTF-8 as the process's code page (Windows 10 1903 on): argv, the A
  # functions and the engine then agree on paths a user's name puts outside
  # ASCII, where the ANSI code page would garble them (#126).
  file(WRITE ${CMAKE_BINARY_DIR}/raccoon_runner.manifest "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
<assembly manifestVersion=\"1.0\" xmlns=\"urn:schemas-microsoft-com:asm.v1\">
  <application xmlns=\"urn:schemas-microsoft-com:asm.v3\">
    <windowsSettings>
      <activeCodePage xmlns=\"http://schemas.microsoft.com/SMI/2019/WindowsSettings\">UTF-8</activeCodePage>
    </windowsSettings>
  </application>
</assembly>
")
  target_sources(raccoon_runner PRIVATE ${CMAKE_BINARY_DIR}/raccoon_runner.manifest)
  target_include_directories(raccoon_runner PRIVATE
    ${CMAKE_SOURCE_DIR}/third_party/flutter_windows/include)
  target_compile_definitions(raccoon_runner PRIVATE RACCOON_HAS_PLUGINS=1)
  add_dependencies(raccoon_runner flutter_windows)
  message(STATUS "Native plugins: on")
  # example/plugins/echo as the desktop template builds a plugin: against
  # the SDK's import library and C++ client wrapper, which need its Windows
  # artifacts (flutter precache --windows). The tests load it.
  find_program(RACCOON_FLUTTER NAMES flutter.bat flutter)
  if(RACCOON_FLUTTER)
    get_filename_component(RACCOON_FLUTTER_REAL ${RACCOON_FLUTTER} REALPATH)
    get_filename_component(RACCOON_SDK ${RACCOON_FLUTTER_REAL} DIRECTORY)
    get_filename_component(RACCOON_SDK ${RACCOON_SDK} DIRECTORY)
    set(RACCOON_FLUTTER_WINDOWS_DIR ${RACCOON_SDK}/bin/cache/artifacts/engine/windows-x64)
  endif()
  if(RACCOON_FLUTTER_WINDOWS_DIR AND EXISTS ${RACCOON_FLUTTER_WINDOWS_DIR}/flutter_windows.dll.lib)
    set(RACCOON_WRAPPER ${RACCOON_FLUTTER_WINDOWS_DIR}/cpp_client_wrapper)
    add_library(flutter INTERFACE)
    target_include_directories(flutter INTERFACE ${RACCOON_FLUTTER_WINDOWS_DIR})
    target_link_libraries(flutter INTERFACE ${RACCOON_FLUTTER_WINDOWS_DIR}/flutter_windows.dll.lib)
    add_library(flutter_wrapper_plugin STATIC
      ${RACCOON_WRAPPER}/core_implementations.cc
      ${RACCOON_WRAPPER}/standard_codec.cc
      ${RACCOON_WRAPPER}/plugin_registrar.cc)
    target_include_directories(flutter_wrapper_plugin PUBLIC ${RACCOON_WRAPPER}/include)
    target_link_libraries(flutter_wrapper_plugin PUBLIC flutter)
    target_compile_features(flutter_wrapper_plugin PUBLIC cxx_std_17)
    # What Flutter's Windows template gives a plugin.
    function(APPLY_STANDARD_SETTINGS TARGET)
      target_compile_features(${TARGET} PUBLIC cxx_std_17)
      target_compile_options(${TARGET} PRIVATE /W4 /WX /wd4100)
      target_compile_options(${TARGET} PRIVATE /EHsc)
      target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
      target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
    endfunction()
    add_subdirectory(example/plugins/echo/windows example_plugins/echo)
    set_target_properties(raccoon_echo_plugin PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/example_plugins/echo)
  else()
    message(STATUS "No Windows artifacts in the SDK cache: example plugin skipped")
  endif()
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
      # gmodule's pkg-config entry exports every symbol of whatever links
      # it, for GtkBuilder's signal lookup, which nothing here uses. On the
      # runner that kept code --gc-sections would drop, and offered its
      # protobuf to a plugin's own references.
      get_target_property(RACCOON_FL_LINK_OPTIONS PkgConfig::RACCOON_FL INTERFACE_LINK_OPTIONS)
      if(RACCOON_FL_LINK_OPTIONS)
        list(REMOVE_ITEM RACCOON_FL_LINK_OPTIONS "-Wl,--export-dynamic" "-rdynamic")
        set_target_properties(PkgConfig::RACCOON_FL PROPERTIES
          INTERFACE_LINK_OPTIONS "${RACCOON_FL_LINK_OPTIONS}")
      endif()
      target_link_libraries(flutter_linux_gtk PUBLIC PkgConfig::RACCOON_FL)
      target_link_libraries(raccoon_runner PRIVATE flutter_linux_gtk)
      # GTK comes with the library's link but the runner calls none of it:
      # only a plugin that uses it loads it (#223), whatever the toolchain's
      # default.
      target_link_options(raccoon_runner PRIVATE -Wl,--as-needed)
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
