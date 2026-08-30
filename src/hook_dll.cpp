// SPDX-License-Identifier: GPL-3.0-only
#include <windows.h>
#include <dinput.h>

#include <atomic>

#include "iat_hook.h"
#include "intercept_create.h"

namespace {

HMODULE g_self = nullptr;
std::atomic<ffb::DirectInput8CreateFunction> g_original{nullptr};
volatile LONG g_initialization_state = 0;

HRESULT WINAPI hooked_direct_input8_create(HINSTANCE instance, DWORD version,
                                           REFIID riid, LPVOID* out,
                                           LPUNKNOWN outer) {
    return ffb::intercept_direct_input8_create(
        g_original.load(std::memory_order_acquire), instance, version, riid, out,
        outer);
}

void patch_loaded_modules() noexcept {
    const auto original = g_original.load(std::memory_order_acquire);
    if (!original) return;
    ffb::patch_loaded_direct_input_imports(
        g_self, reinterpret_cast<void*>(original),
        reinterpret_cast<void*>(&hooked_direct_input8_create));
}

DWORD WINAPI module_monitor(LPVOID) {
    // Most games initialize DirectInput within seconds.  Keep a bounded monitor
    // for modules loaded later without installing permanent loader callbacks.
    for (DWORD cycle = 0; cycle < 720; ++cycle) {
        Sleep(cycle < 120 ? 250 : 1000);
        patch_loaded_modules();
    }
    return 0;
}

}  // namespace

extern "C" __declspec(dllexport) DWORD WINAPI FFBHookInitialize(LPVOID) {
    const LONG previous =
        InterlockedCompareExchange(&g_initialization_state, 1, 0);
    if (previous == 2) return 1;
    if (previous != 0) return 12;

    HMODULE real_dinput =
        LoadLibraryExW(L"dinput8.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!real_dinput) {
        InterlockedExchange(&g_initialization_state, 0);
        return 10;
    }

    const auto original = reinterpret_cast<ffb::DirectInput8CreateFunction>(
        GetProcAddress(real_dinput, "DirectInput8Create"));
    if (!original) {
        FreeLibrary(real_dinput);
        InterlockedExchange(&g_initialization_state, 0);
        return 11;
    }

    g_original.store(original, std::memory_order_release);
    patch_loaded_modules();

    HANDLE monitor = CreateThread(nullptr, 0, module_monitor, nullptr, 0, nullptr);
    if (monitor) CloseHandle(monitor);
    InterlockedExchange(&g_initialization_state, 2);
    return 1;
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = module;
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}
