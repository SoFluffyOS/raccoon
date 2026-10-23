cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "raccoon_static_core")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

# Static, as FlutterFire's plugins are: an app's .exe links it.
add_library(${PLUGIN_NAME} STATIC
  "raccoon_static_core_plugin.cpp"
  "include/raccoon_static_core/raccoon_static_core_plugin.h"
)
apply_standard_settings(${PLUGIN_NAME})
target_compile_definitions(${PLUGIN_NAME} PUBLIC FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PUBLIC flutter flutter_wrapper_plugin)

set(raccoon_static_core_bundled_libraries
  ""
  PARENT_SCOPE
)
