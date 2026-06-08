# Windows plugin entry point. Builds the shared engine library from ../src and
# hands the artifact to Flutter's bundling step.
cmake_minimum_required(VERSION 3.15)
set(PROJECT_NAME "loopy_engine")
project(${PROJECT_NAME} LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(loopy_engine_bundled_libraries
  $<TARGET_FILE:loopy_engine>
  PARENT_SCOPE
)
