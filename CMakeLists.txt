# SPDX-License-Identifier: GPL-3.0-only
cmake_minimum_required(VERSION 3.20)
project(ffb_interceptor VERSION 0.3.0 LANGUAGES CXX)

option(FFB_STABLE_PACKAGE
    "Require trusted Authenticode signatures for Manager package actions" OFF)
set(FFB_EXPECTED_SIGNER_SHA256 "" CACHE STRING
    "Optional SHA-256 certificate thumbprint required in stable packages")
set(_FFB_EXPECTED_SIGNER_SHA256_NORMALIZED "")
if (FFB_EXPECTED_SIGNER_SHA256)
    string(LENGTH "${FFB_EXPECTED_SIGNER_SHA256}" FFB_SIGNER_LENGTH)
    if (NOT FFB_SIGNER_LENGTH EQUAL 64 OR
        NOT FFB_EXPECTED_SIGNER_SHA256 MATCHES "^[0-9A-Fa-f]+$")
        message(FATAL_ERROR
            "FFB_EXPECTED_SIGNER_SHA256 must contain exactly 64 hexadecimal characters")
    endif()
    string(TOUPPER "${FFB_EXPECTED_SIGNER_SHA256}"
        _FFB_EXPECTED_SIGNER_SHA256_NORMALIZED)
endif()

if (FFB_STABLE_PACKAGE)
    set(_FFB_MANAGER_POLICY_MODE "STABLE")
    if (_FFB_EXPECTED_SIGNER_SHA256_NORMALIZED)
        set(_FFB_MANAGER_POLICY_SIGNER
            "${_FFB_EXPECTED_SIGNER_SHA256_NORMALIZED}")
    else()
        set(_FFB_MANAGER_POLICY_SIGNER "UNPINNED")
    endif()
else()
    set(_FFB_MANAGER_POLICY_MODE "EXPERIMENTAL")
    set(_FFB_MANAGER_POLICY_SIGNER "NONE")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if (MSVC)
    # Release archives are extracted into user-writable directories. Keep the
    # Microsoft runtime inside each binary and force statically imported
    # Windows dependencies to resolve only from System32, so an app-local DLL
    # cannot run before Manager/Launcher policy checks reach main().
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    add_link_options("/DEPENDENTLOADFLAG:0x800")
endif()

add_library(dinput8 SHARED
    src/dllmain.cpp
    src/proxy.cpp
    src/intercept_create.cpp
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

add_library(ffb_hook SHARED
    src/hook_dll.cpp
    src/iat_hook.cpp
    src/intercept_create.cpp
    src/wrapper_effect.cpp
    src/wrapper_device8.cpp
    src/wrapper_dinput8.cpp
    src/telemetry_protocol.cpp
    src/telemetry.cpp
)
set_target_properties(ffb_hook PROPERTIES OUTPUT_NAME "FFBInterceptor.Hook")
target_include_directories(ffb_hook PRIVATE src)
target_compile_definitions(ffb_hook PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    DIRECTINPUT_VERSION=0x0800
    _CRT_SECURE_NO_WARNINGS
    FFB_PROTOCOL_VERSION=1
    FFB_BUILD_VERSION="${PROJECT_VERSION}"
)
target_link_libraries(ffb_hook PRIVATE ole32 dxguid)

add_executable(ffb_launcher
    launcher/launcher_main.cpp
    launcher/injector.cpp
    launcher/pe_arch.cpp
)
set_target_properties(ffb_launcher PROPERTIES
    OUTPUT_NAME "FFBInterceptor.Launcher"
)
target_include_directories(ffb_launcher PRIVATE launcher)
target_compile_definitions(ffb_launcher PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    UNICODE
    _UNICODE
)

add_executable(ffb_e2e_probe tests/e2e/directinput_probe.cpp)
set_target_properties(ffb_e2e_probe PROPERTIES
    OUTPUT_NAME "FFBInterceptor.E2E.Probe"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/e2e"
)
target_compile_definitions(ffb_e2e_probe PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    DIRECTINPUT_VERSION=0x0800
    UNICODE
    _UNICODE
)
target_link_libraries(ffb_e2e_probe PRIVATE dxguid)

add_executable(ffb_manager WIN32
    launcher/manager_main.cpp
    launcher/manager_model.cpp
    launcher/pe_arch.cpp
)
set_target_properties(ffb_manager PROPERTIES
    OUTPUT_NAME "FFBInterceptor.Manager"
)
target_include_directories(ffb_manager PRIVATE launcher)
target_compile_definitions(ffb_manager PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    UNICODE
    _UNICODE
    FFB_BUILD_VERSION="${PROJECT_VERSION}"
    FFB_STABLE_PACKAGE=$<BOOL:${FFB_STABLE_PACKAGE}>
    FFB_EXPECTED_SIGNER_SHA256="${_FFB_EXPECTED_SIGNER_SHA256_NORMALIZED}"
    FFB_MANAGER_POLICY_SIGNER="${_FFB_MANAGER_POLICY_SIGNER}"
)
target_link_libraries(ffb_manager PRIVATE
    advapi32
    bcrypt
    comctl32
    comdlg32
    crypt32
    ole32
    shell32
    uuid
    wintrust
)

# Suppress noisy warnings from Windows SDK COM macros
if (MSVC)
    target_compile_options(dinput8 PRIVATE /W4 /WX /EHsc)
    target_compile_options(ffb_hook PRIVATE /W4 /WX /EHsc)
    target_compile_options(ffb_launcher PRIVATE /W4 /WX /EHsc /utf-8)
    target_compile_options(ffb_e2e_probe PRIVATE /W4 /WX /EHsc)
    target_compile_options(ffb_manager PRIVATE /W4 /WX /EHsc /utf-8)
    target_link_options(ffb_manager PRIVATE
        "/MANIFESTUAC:level='asInvoker' uiAccess='false'"
    )
else()
    target_compile_options(dinput8 PRIVATE -Wall -Wextra -Wpedantic -Werror)
    target_compile_options(ffb_hook PRIVATE -Wall -Wextra -Wpedantic -Werror)
    target_compile_options(ffb_launcher PRIVATE -Wall -Wextra -Wpedantic -Werror)
    target_compile_options(ffb_e2e_probe PRIVATE -Wall -Wextra -Wpedantic -Werror)
    target_compile_options(ffb_manager PRIVATE -Wall -Wextra -Wpedantic -Werror)
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
        src/intercept_create.cpp
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

    add_executable(ffb_telemetry_tests
        tests/cpp/telemetry_tests.cpp
        src/telemetry_protocol.cpp
        src/telemetry.cpp
    )
    target_include_directories(ffb_telemetry_tests PRIVATE src)
    target_compile_definitions(ffb_telemetry_tests PRIVATE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
        FFB_TESTING
    )
    if (MSVC)
        target_compile_options(ffb_telemetry_tests PRIVATE /W4 /WX /EHsc)
    else()
        target_compile_options(ffb_telemetry_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    target_link_libraries(ffb_telemetry_tests PRIVATE ole32 dxguid)
    add_test(NAME ffb_telemetry_tests COMMAND ffb_telemetry_tests)

    add_executable(ffb_iat_hook_tests
        tests/cpp/iat_hook_tests.cpp
        src/iat_hook.cpp
    )
    target_include_directories(ffb_iat_hook_tests PRIVATE src)
    target_compile_definitions(ffb_iat_hook_tests PRIVATE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
    )
    if (MSVC)
        target_compile_options(ffb_iat_hook_tests PRIVATE /W4 /WX /EHsc)
    else()
        target_compile_options(ffb_iat_hook_tests PRIVATE
            -Wall -Wextra -Wpedantic -Werror)
    endif()
    add_test(NAME ffb_iat_hook_tests COMMAND ffb_iat_hook_tests)

    add_executable(ffb_manager_tests
        launcher/tests/manager_model_tests.cpp
        launcher/manager_model.cpp
    )
    target_include_directories(ffb_manager_tests PRIVATE launcher)
    target_compile_definitions(ffb_manager_tests PRIVATE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
        UNICODE
        _UNICODE
        FFB_STABLE_PACKAGE=0
        FFB_EXPECTED_SIGNER_SHA256=""
        FFB_MANAGER_POLICY_SIGNER="NONE"
    )
    if (MSVC)
        target_compile_options(ffb_manager_tests PRIVATE /W4 /WX /EHsc /utf-8)
    else()
        target_compile_options(ffb_manager_tests PRIVATE
            -Wall -Wextra -Wpedantic -Werror)
    endif()
    target_link_libraries(ffb_manager_tests PRIVATE
        advapi32
        bcrypt
        crypt32
        ole32
        shell32
        uuid
        wintrust
    )
    add_dependencies(ffb_manager_tests ffb_manager)
    add_test(NAME ffb_manager_tests COMMAND ffb_manager_tests
        "$<TARGET_FILE:ffb_manager>"
        "${_FFB_MANAGER_POLICY_MODE}"
        "${_FFB_MANAGER_POLICY_SIGNER}")
endif()
