# Linux plugin entry point. Flutter invokes this; it builds the shared engine
# library from ../src and hands the artifact to the bundling step.
cmake_minimum_required(VERSION 3.15)
set(PROJECT_NAME "loopy_engine")
project(${PROJECT_NAME} LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# No Dart-facing symbols are registered the method-channel way for FFI plugins.
set(loopy_engine_bundled_libraries
  $<TARGET_FILE:loopy_engine>
  PARENT_SCOPE
)
