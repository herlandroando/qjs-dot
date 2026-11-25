cmake_minimum_required(VERSION 3.10...3.31)

project(qjs_dot_library VERSION 0.1.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)

add_library(qjs_dot SHARED
  "qjs_bridge.c"
  "quickjs-ng/dtoa.c"
  "quickjs-ng/libregexp.c"
  "quickjs-ng/libunicode.c"
  "quickjs-ng/quickjs.c"
)

set_target_properties(qjs_dot PROPERTIES
  PUBLIC_HEADER "qjs_bridge.h"
  OUTPUT_NAME "qjs_dot"
)

target_include_directories(qjs_dot PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/quickjs-ng"
)

target_compile_definitions(qjs_dot PUBLIC DART_SHARED_LIB)
target_compile_definitions(qjs_dot PRIVATE
  QJS_DOT_BUILD
  QUICKJS_NG_BUILD
  _GNU_SOURCE
)

if(WIN32)
  target_compile_definitions(qjs_dot PRIVATE
    WIN32_LEAN_AND_MEAN
    _WIN32_WINNT=0x0601
    _CRT_SECURE_NO_WARNINGS
    _CRT_NONSTDC_NO_DEPRECATE
  )
endif()

if(MSVC)
  target_compile_options(qjs_dot PRIVATE
    /experimental:c11atomics
    /wd4018
    /wd4061
    /wd4100
    /wd4200
    /wd4242
    /wd4244
    /wd4245
    /wd4267
    /wd4388
    /wd4389
    /wd4456
    /wd4457
    /wd4710
    /wd4711
    /wd4820
    /wd4996
    /wd5045
  )
else()
  target_compile_options(qjs_dot PRIVATE
    -funsigned-char
    -Wall
    -Wno-implicit-fallthrough
    -Wno-sign-compare
    -Wno-missing-field-initializers
    -Wno-unused-parameter
    -Wno-unused-but-set-variable
    -Wno-unused-result
  )
endif()

if(NOT WIN32)
  find_package(Threads REQUIRED)
  target_link_libraries(qjs_dot PRIVATE m ${CMAKE_DL_LIBS} Threads::Threads)
endif()

if(ANDROID)
  # Support 16 KB ELF page alignment for modern Android devices.
  target_link_options(qjs_dot PRIVATE "-Wl,-z,max-page-size=16384")
endif()
