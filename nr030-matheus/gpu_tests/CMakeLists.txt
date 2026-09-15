# SPDX-License-Identifier: GPL-3.0-only
cmake_minimum_required(VERSION 3.20)
project(Nr030WarpChecks LANGUAGES CXX)
if(NOT WIN32)
  message(FATAL_ERROR "The D3D12 executor and WARP checks require Windows SDK / MSVC.")
endif()

add_library(nr030_shader_executor STATIC shader_executor.cpp)
target_include_directories(nr030_shader_executor PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_features(nr030_shader_executor PUBLIC cxx_std_17)
target_link_libraries(nr030_shader_executor PUBLIC d3d12 dxgi d3dcompiler)
target_compile_definitions(nr030_shader_executor PUBLIC NOMINMAX WIN32_LEAN_AND_MEAN)

set(NR030_SHADER_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../components/shaders"
    CACHE PATH "Production HLSL source directory")
set(NR030_SHADER_BIN_DIR "${CMAKE_CURRENT_BINARY_DIR}/shaders"
    CACHE PATH "Shared compiled shaders for the add-on resources and WARP")
add_executable(nr030_compile_shader_blobs "../components/tools/compile_shaders.cpp")
target_compile_features(nr030_compile_shader_blobs PRIVATE cxx_std_17)
target_link_libraries(nr030_compile_shader_blobs PRIVATE d3dcompiler)
set(_nr030_shader_names area_downsample depth_nearest motion_nearest matched_residual_resolve)
set(_nr030_sources)
set(_nr030_blobs)
foreach(_shader IN LISTS _nr030_shader_names)
  list(APPEND _nr030_sources "${NR030_SHADER_SOURCE_DIR}/${_shader}.hlsl")
  list(APPEND _nr030_blobs "${NR030_SHADER_BIN_DIR}/${_shader}.cso")
endforeach()
add_custom_command(
  OUTPUT ${_nr030_blobs}
  COMMAND ${CMAKE_COMMAND} -E make_directory "${NR030_SHADER_BIN_DIR}"
  COMMAND $<TARGET_FILE:nr030_compile_shader_blobs>
          "${NR030_SHADER_SOURCE_DIR}" "${NR030_SHADER_BIN_DIR}"
  DEPENDS nr030_compile_shader_blobs ${_nr030_sources}
  COMMENT "Compile the four shared production DXBC shader blobs"
  VERBATIM)
add_custom_target(nr030_shader_blobs ALL DEPENDS ${_nr030_blobs})

add_executable(nr030_warp_checks warp_checks.cpp)
target_link_libraries(nr030_warp_checks PRIVATE nr030_shader_executor)
add_dependencies(nr030_warp_checks nr030_shader_blobs)
if(MSVC)
  foreach(_target nr030_shader_executor nr030_warp_checks nr030_compile_shader_blobs)
    target_compile_options(${_target} PRIVATE /W4 /WX /fp:strict /utf-8 /permissive-)
  endforeach()
endif()
enable_testing()
add_test(NAME nr030_warp_checks
  COMMAND nr030_warp_checks "${NR030_SHADER_SOURCE_DIR}" "${NR030_SHADER_BIN_DIR}"
                           "${CMAKE_CURRENT_BINARY_DIR}/warp_results.json")
set_tests_properties(nr030_warp_checks PROPERTIES TIMEOUT 120)

