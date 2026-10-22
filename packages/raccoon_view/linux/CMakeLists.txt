cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "raccoon_view")
project(${PROJECT_NAME} LANGUAGES CXX)

# The host side of Raccoon's GPU buffers: takes the runner's dmabufs from its
# GPU socket and shows them as a Flutter texture. Needs EGL and GLES 2
# (libegl1-mesa-dev, libgles2-mesa-dev on Debian).
set(PLUGIN_NAME "raccoon_view_plugin")

list(APPEND PLUGIN_SOURCES
  "raccoon_view_plugin.cc"
)

add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
pkg_check_modules(RACCOON_VIEW_GL REQUIRED IMPORTED_TARGET egl glesv2)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::RACCOON_VIEW_GL)

set(raccoon_view_bundled_libraries
  ""
  PARENT_SCOPE
)
