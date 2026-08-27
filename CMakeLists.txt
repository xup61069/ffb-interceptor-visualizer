cmake_minimum_required(VERSION 3.20)
project(ffb_interceptor LANGUAGES CXX)

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
    target_compile_definitions(ffb_protocol_tests PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
    if (MSVC)
        target_compile_options(ffb_protocol_tests PRIVATE /W4 /WX /EHsc)
    else()
        target_compile_options(ffb_protocol_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    target_link_libraries(ffb_protocol_tests PRIVATE ole32 dxguid)
    add_test(NAME ffb_protocol_tests COMMAND ffb_protocol_tests)
endif()
