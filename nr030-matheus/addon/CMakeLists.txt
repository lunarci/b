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
add_library(MatheusNR030 SHARED MatheusNR030.cpp lifetime.cpp predication.cpp xefg_barrier_guard.cpp "${_resources}")
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

# Use the exact production lifetime implementation and real queue/Reset hooks.
# Queue fences can be deliberately delayed; no game or NR engine is mocked.
add_executable(nr030_lifetime_checks lifetime_checks.cpp lifetime.cpp)
target_compile_features(nr030_lifetime_checks PRIVATE cxx_std_17)
target_compile_definitions(nr030_lifetime_checks PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(nr030_lifetime_checks PRIVATE minhook d3d12 dxgi)
if(MSVC)
  target_compile_options(nr030_lifetime_checks PRIVATE /W4 /WX /permissive- /utf-8)
endif()
add_test(NAME nr030_lifetime_checks
  COMMAND nr030_lifetime_checks "${CMAKE_CURRENT_BINARY_DIR}/lifetime_results.json")
set_tests_properties(nr030_lifetime_checks PROPERTIES TIMEOUT 40)

# Admission uses real resource descriptions and the same production contract.
# No NR inference or game performance result is inferred from these checks.
add_executable(nr030_input_checks input_checks.cpp)
target_compile_features(nr030_input_checks PRIVATE cxx_std_17)
target_compile_definitions(nr030_input_checks PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(nr030_input_checks PRIVATE d3d12 dxgi)
if(MSVC)
  target_compile_options(nr030_input_checks PRIVATE /W4 /WX /permissive- /utf-8)
endif()
add_test(NAME nr030_input_checks
  COMMAND nr030_input_checks "${CMAKE_CURRENT_BINARY_DIR}/input_results.json")
set_tests_properties(nr030_input_checks PROPERTIES TIMEOUT 30)

# Include the production adapter in the test translation unit. This reaches the
# actual private After() without exporting a test API or enabling any game hook.
add_executable(nr030_handoff_checks handoff_checks.cpp lifetime.cpp predication.cpp xefg_barrier_guard.cpp)
target_compile_features(nr030_handoff_checks PRIVATE cxx_std_17)
target_compile_definitions(nr030_handoff_checks PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN
  NR030_ENABLE_EXPERIMENTAL_RUNTIME=0)
target_link_libraries(nr030_handoff_checks PRIVATE minhook nr030_shader_executor bcrypt)
if(MSVC)
  target_compile_options(nr030_handoff_checks PRIVATE /W4 /permissive- /utf-8 /fp:strict)
endif()
add_test(NAME nr030_handoff_checks
  COMMAND nr030_handoff_checks "${CMAKE_CURRENT_BINARY_DIR}/handoff_results.json")
set_tests_properties(nr030_handoff_checks PROPERTIES TIMEOUT 30)

# Reproduce private NR predication state changes on real WARP buffers. The
# production tracker and guard must preserve the original conditional result.
add_executable(nr030_predication_checks predication_checks.cpp predication.cpp lifetime.cpp)
target_compile_features(nr030_predication_checks PRIVATE cxx_std_17)
target_compile_definitions(nr030_predication_checks PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(nr030_predication_checks PRIVATE minhook d3d12 dxgi)
if(MSVC)
  target_compile_options(nr030_predication_checks PRIVATE /W4 /WX /permissive- /utf-8)
endif()
add_test(NAME nr030_predication_checks
  COMMAND nr030_predication_checks "${CMAKE_CURRENT_BINARY_DIR}/predication_results.json")
set_tests_properties(nr030_predication_checks PROPERTIES TIMEOUT 60)

# Validate the exact-site policy with a D3D12 debug-layer negative control,
# real WARP copies, and unchanged legacy/other-call forwarding.
add_executable(nr030_xefg_barrier_checks xefg_barrier_guard_checks.cpp xefg_barrier_guard.cpp)
target_compile_features(nr030_xefg_barrier_checks PRIVATE cxx_std_17)
target_compile_definitions(nr030_xefg_barrier_checks PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(nr030_xefg_barrier_checks PRIVATE minhook d3d12 dxgi bcrypt)
if(MSVC)
  target_compile_options(nr030_xefg_barrier_checks PRIVATE /W4 /WX /permissive- /utf-8)
endif()
add_test(NAME nr030_xefg_barrier_checks
  COMMAND nr030_xefg_barrier_checks "${CMAKE_CURRENT_BINARY_DIR}/xefg_barrier_results.json")
set_tests_properties(nr030_xefg_barrier_checks PROPERTIES TIMEOUT 60)
