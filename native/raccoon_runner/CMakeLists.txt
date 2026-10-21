cmake_minimum_required(VERSION 3.20)
project(raccoon_runner CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Directory holding flutter_embedder.h for the engine revision in use. The
# engine library itself is loaded at run time with --engine-dir, so one runner
# binary serves several runtimes.
set(RACCOON_ENGINE_DIR "" CACHE PATH "Directory with flutter_embedder.h")
if(NOT RACCOON_ENGINE_DIR)
  message(FATAL_ERROR "Set -DRACCOON_ENGINE_DIR to a directory holding flutter_embedder.h (see tool/engine_dir.sh)")
endif()

add_executable(raccoon_runner
  src/main.cc
  src/engine_loader.cc
  src/platform_task_runner.cc
  src/software_frame.cc
)
target_include_directories(raccoon_runner PRIVATE ${RACCOON_ENGINE_DIR} src)
target_compile_options(raccoon_runner PRIVATE -Wall -Wextra)
target_link_libraries(raccoon_runner PRIVATE dl pthread)
