cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "raccoon_view")
project(${PROJECT_NAME} LANGUAGES CXX)

# The host side of Raccoon's GPU buffers on Windows: takes the runner's ring
# of shared D3D11 textures from its GPU socket and shows them as a Flutter
# texture, by their shared handles.
set(PLUGIN_NAME "raccoon_view_plugin")

add_library(${PLUGIN_NAME} SHARED
  "raccoon_view_plugin.cpp"
  "include/raccoon_view/raccoon_view_plugin.h"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin ws2_32)

set(raccoon_view_bundled_libraries
  ""
  PARENT_SCOPE
)
