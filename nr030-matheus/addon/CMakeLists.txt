# SPDX-License-Identifier: GPL-3.0-only
cmake_minimum_required(VERSION 3.20)
if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "MatheusNR030 requires Windows x64.")
endif()
enable_language(RC)
option(NR030_ENABLE_EXPERIMENTAL_RUNTIME "Enable exact-C7 experimental game hooks" OFF)
set(NR030_SOURCE_COMMIT "unrecorded" CACHE STRING "Exact source commit embedded in the ASI")
include(FetchContent)
FetchContent_Declare(nr030_minhook
  GIT_REPOSITORY https://github.com/TsudaKageyu/minhook.git
  GIT_TAG c3fcafdc10146beb5919319d0683e44e3c30d537
  GIT_SHALLOW FALSE)
FetchContent_MakeAvailable(nr030_minhook)

# The WARP target tests the same compiled files that are embedded in this ASI.
if(NOT TARGET nr030_shader_blobs OR NOT DEFINED NR030_SHADER_BIN_DIR)
  message(FATAL_ERROR "Add gpu_tests before addon so shared production DXBC exists.")
endif()
set(_resources "${CMAKE_CURRENT_BINARY_DIR}/MatheusNR030.rc")
file(WRITE "${_resources}" "#include <windows.h>\n")
set(_shader_names area_downsample depth_nearest motion_nearest matched_residual_resolve)
set(_resource_id 101)
foreach(_shader IN LISTS _shader_names)
  file(APPEND "${_resources}" "${_resource_id} RCDATA \"${NR030_SHADER_BIN_DIR}/${_shader}.cso\"\n")
  math(EXPR _resource_id "${_resource_id} + 1")
endforeach()
add_library(MatheusNR030 SHARED MatheusNR030.cpp lifetime.cpp "${_resources}")
set_target_properties(MatheusNR030 PROPERTIES PREFIX "" SUFFIX ".asi")
target_compile_features(MatheusNR030 PRIVATE cxx_std_17)
target_link_libraries(MatheusNR030 PRIVATE minhook nr030_shader_executor bcrypt)
target_compile_definitions(MatheusNR030 PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN
  NR030_ENABLE_EXPERIMENTAL_RUNTIME=$<BOOL:${NR030_ENABLE_EXPERIMENTAL_RUNTIME}>
  NR030_SOURCE_COMMIT="${NR030_SOURCE_COMMIT}")
add_dependencies(MatheusNR030 nr030_shader_blobs)
if(MSVC)
  target_compile_options(MatheusNR030 PRIVATE /W4 /permissive- /utf-8 /fp:strict)
endif()
add_custom_command(TARGET MatheusNR030 POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/MatheusNR030.ini" "$<TARGET_FILE_DIR:MatheusNR030>/MatheusNR030.ini")

# Exercise the final Windows binary without activating a runtime or game hook.
# Its four resources must match the same CSOs supplied to the WARP test.
add_executable(nr030_addon_smoke smoke_checks.cpp)
target_compile_features(nr030_addon_smoke PRIVATE cxx_std_17)
target_compile_definitions(nr030_addon_smoke PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
add_dependencies(nr030_addon_smoke MatheusNR030 nr030_shader_blobs)
if(MSVC)
  target_compile_options(nr030_addon_smoke PRIVATE /W4 /WX /permissive- /utf-8)
endif()
add_test(NAME nr030_addon_smoke
  COMMAND nr030_addon_smoke "$<TARGET_FILE:MatheusNR030>" "${NR030_SHADER_BIN_DIR}"
                           "${CMAKE_CURRENT_BINARY_DIR}/smoke")
set_tests_properties(nr030_addon_smoke PROPERTIES TIMEOUT 10)
