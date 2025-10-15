cmake_minimum_required(VERSION 3.16)

project(atlasgen)
add_executable(atlasgen src/main.cpp)
target_compile_features(atlasgen PUBLIC cxx_std_20)

set(ZLIB_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(ZLIB_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(ZLIB_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(deps/zlib)
target_link_libraries(atlasgen zlibstatic)
set(ZLIB_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/deps/zlib")
set(ZLIB_LIBRARY "${CMAKE_CURRENT_BINARY_DIR}/deps/zlib/Debug/zsd.lib")

set(FT_DISABLE_HARFBUZZ ON CACHE BOOL "" FORCE)
add_subdirectory(deps/freetype)
target_link_libraries(atlasgen freetype)

set(PNG_TOOLS OFF CACHE BOOL "" FORCE)
set(PNG_EXECUTABLES OFF CACHE BOOL "" FORCE)
set(PNG_SHARED OFF CACHE BOOL "" FORCE)
set(PNG_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(deps/libpng)
target_link_libraries(atlasgen png_static)

include_directories(deps/stb)