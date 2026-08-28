# SPDX-License-Identifier: GPL-3.0-only
cmake_minimum_required(VERSION 3.20)
project(ffb_interceptor VERSION 0.1.11 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(dinput8 SHARED
    src/dllmain.cpp
    src/proxy.cpp
    src/wrapper_effect.cpp
    src/wrapper_device8.cpp
    src/wrapper_dinput8.cpp
    src/telemetry_protocol.cpp
    src/telemetry.cpp
    dinput8.def
)

target_include_directories(dinput8 PRIVATE src)

target_compile_definitions(dinput8 PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    DIRECTINPUT_VERSION=0x0800
    _CRT_SECURE_NO_WARNINGS
    FFB_PROTOCOL_VERSION=1
    FFB_BUILD_VERSION="${PROJECT_VERSION}"
)

target_link_libraries(dinput8 PRIVATE
    ole32
    dxguid
)

# Suppress noisy warnings from Windows SDK COM macros
if (MSVC)
    target_compile_options(dinput8 PRIVATE /W4 /WX /EHsc)
else()
    target_compile_options(dinput8 PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(ffb_protocol_tests tests/cpp/protocol_tests.cpp src/telemetry_protocol.cpp)
    target_include_directories(ffb_protocol_tests PRIVATE src)
    target_compile_definitions(ffb_protocol_tests PRIVATE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
        FFB_SOURCE_DIR="${CMAKE_SOURCE_DIR}"
    )
    if (MSVC)
        target_compile_options(ffb_protocol_tests PRIVATE /W4 /WX /EHsc)
    else()
        target_compile_options(ffb_protocol_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    target_link_libraries(ffb_protocol_tests PRIVATE ole32 dxguid)
    add_test(NAME ffb_protocol_tests COMMAND ffb_protocol_tests)

    add_executable(ffb_wrapper_tests
        tests/cpp/wrapper_tests.cpp
        src/wrapper_effect.cpp
        src/telemetry_protocol.cpp
        src/telemetry.cpp
    )
    target_include_directories(ffb_wrapper_tests PRIVATE src)
    target_compile_definitions(ffb_wrapper_tests PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
    if (MSVC)
        target_compile_options(ffb_wrapper_tests PRIVATE /W4 /WX /EHsc)
    else()
        target_compile_options(ffb_wrapper_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    target_link_libraries(ffb_wrapper_tests PRIVATE ole32 dxguid)
    add_test(NAME ffb_wrapper_tests COMMAND ffb_wrapper_tests)

    add_executable(ffb_dinput_wrapper_tests
        tests/cpp/dinput_wrapper_tests.cpp
        src/wrapper_dinput8.cpp
        src/wrapper_device8.cpp
        src/wrapper_effect.cpp
        src/telemetry_protocol.cpp
        src/telemetry.cpp
    )
    target_include_directories(ffb_dinput_wrapper_tests PRIVATE src)
    target_compile_definitions(ffb_dinput_wrapper_tests PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
    if (MSVC)
        target_compile_options(ffb_dinput_wrapper_tests PRIVATE /W4 /WX /EHsc)
    else()
        target_compile_options(ffb_dinput_wrapper_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    target_link_libraries(ffb_dinput_wrapper_tests PRIVATE ole32 dxguid)
    add_test(NAME ffb_dinput_wrapper_tests COMMAND ffb_dinput_wrapper_tests)

    add_executable(ffb_performance_tests
        tests/cpp/performance_tests.cpp
        src/telemetry_protocol.cpp
        src/telemetry.cpp
    )
    target_include_directories(ffb_performance_tests PRIVATE src)
    target_compile_definitions(ffb_performance_tests PRIVATE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
        FFB_TESTING
    )
    if (MSVC)
        target_compile_options(ffb_performance_tests PRIVATE /W4 /WX /EHsc)
    else()
        target_compile_options(ffb_performance_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    target_link_libraries(ffb_performance_tests PRIVATE ole32 dxguid)
    add_test(NAME ffb_performance_tests COMMAND ffb_performance_tests)
endif()
