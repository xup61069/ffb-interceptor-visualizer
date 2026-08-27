// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Valmantas Paliksa
#include "proxy.h"

bool OriginalDI8::load() {
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    static BOOL loaded = FALSE;
    InitOnceExecuteOnce(&once, [](PINIT_ONCE, PVOID, PVOID*) -> BOOL {
        auto& original = OriginalDI8::instance();
        original.hModule = LoadLibraryExW(L"dinput8.dll", nullptr,
                                          LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!original.hModule) return TRUE;
        original.DirectInput8Create = reinterpret_cast<PFN_DirectInput8Create>(
            GetProcAddress(original.hModule, "DirectInput8Create"));
        original.DllCanUnloadNow = reinterpret_cast<PFN_DllCanUnloadNow>(
            GetProcAddress(original.hModule, "DllCanUnloadNow"));
        original.DllGetClassObject = reinterpret_cast<PFN_DllGetClassObject>(
            GetProcAddress(original.hModule, "DllGetClassObject"));
        original.DllRegisterServer = reinterpret_cast<PFN_DllRegisterServer>(
            GetProcAddress(original.hModule, "DllRegisterServer"));
        original.DllUnregisterServer = reinterpret_cast<PFN_DllUnregisterServer>(
            GetProcAddress(original.hModule, "DllUnregisterServer"));
        loaded = original.DirectInput8Create != nullptr;
        return TRUE;
    }, nullptr, nullptr);
    return loaded != FALSE;
}

OriginalDI8& OriginalDI8::instance() {
    static OriginalDI8 original;
    return original;
}
