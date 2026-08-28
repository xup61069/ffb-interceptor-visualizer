// SPDX-License-Identifier: GPL-3.0-only
#define INITGUID
#include <windows.h>
#include <dinput.h>

#include <new>
#include "proxy.h"
#include "telemetry.h"
#include "wrapper_dinput8.h"

static HMODULE g_module = nullptr;

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = module;
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}

extern "C" HRESULT WINAPI DirectInput8Create(HINSTANCE instance, DWORD version,
                                               REFIID riid, LPVOID* out,
                                               LPUNKNOWN outer) {
    if (!out) return E_POINTER;
    *out = nullptr;
    auto& original = OriginalDI8::instance();
    if (!original.load() || !original.DirectInput8Create) return DIERR_NOTINITIALIZED;
    const HRESULT hr = original.DirectInput8Create(instance, version, riid, out, outer);
    if (FAILED(hr) || !*out || outer != nullptr) return hr;

    ffb::Telemetry::instance().start();
    if (riid == IID_IDirectInput8W) {
        auto* wrapped = new (std::nothrow) WrapperDirectInput8W(
            static_cast<IDirectInput8W*>(*out));
        if (wrapped && wrapped->valid()) {
            *out = static_cast<IDirectInput8W*>(wrapped);
        } else if (wrapped) {
            wrapped->discard_unpublished();
        }
    } else if (riid == IID_IDirectInput8A) {
        auto* wrapped = new (std::nothrow) WrapperDirectInput8A(
            static_cast<IDirectInput8A*>(*out));
        if (wrapped && wrapped->valid()) {
            *out = static_cast<IDirectInput8A*>(wrapped);
        } else if (wrapped) {
            wrapped->discard_unpublished();
        }
    }
    return hr;
}

extern "C" HRESULT WINAPI DllCanUnloadNow() {
    auto& original = OriginalDI8::instance();
    if (!original.load() || !original.DllCanUnloadNow) return S_FALSE;
    return original.DllCanUnloadNow();
}

extern "C" HRESULT WINAPI DllGetClassObject(REFCLSID clsid, REFIID riid, LPVOID* out) {
    auto& original = OriginalDI8::instance();
    if (!original.load() || !original.DllGetClassObject) return CLASS_E_CLASSNOTAVAILABLE;
    return original.DllGetClassObject(clsid, riid, out);
}

extern "C" HRESULT WINAPI DllRegisterServer() {
    auto& original = OriginalDI8::instance();
    if (!original.load() || !original.DllRegisterServer) return E_FAIL;
    return original.DllRegisterServer();
}

extern "C" HRESULT WINAPI DllUnregisterServer() {
    auto& original = OriginalDI8::instance();
    if (!original.load() || !original.DllUnregisterServer) return E_FAIL;
    return original.DllUnregisterServer();
}
