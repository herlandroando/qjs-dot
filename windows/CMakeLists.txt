cmake_minimum_required(VERSION 3.14...3.31)

set(PROJECT_NAME "qjs_dot")
project(${PROJECT_NAME} LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(qjs_dot_bundled_libraries
  $<TARGET_FILE:qjs_dot>
  PARENT_SCOPE
)
