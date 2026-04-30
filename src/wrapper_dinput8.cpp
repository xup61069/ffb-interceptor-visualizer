// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Valmantas Paliksa
#include "wrapper_dinput8.h"
#include "wrapper_device8.h"
#include "ffb_filter.h"
#include "config.h"
#include "logger.h"
#include <memory>
#include <string>

// ============================================================================
// Callback trampolines for device-hide filtering in EnumDevices
// ============================================================================

// Helper: convert a narrow (ANSI) product name to wide for policy lookups.
static std::wstring ansiToWide(const char* s) {
    int len = MultiByteToWideChar(CP_ACP, 0, s, -1, nullptr, 0);
    std::wstring ws(len, L'\0');
    MultiByteToWideChar(CP_ACP, 0, s, -1, ws.data(), len);
    if (!ws.empty() && ws.back() == L'\0') ws.pop_back();
    return ws;
}

struct EnumDevCtxW {
    LPDIENUMDEVICESCALLBACKW userCb;
    LPVOID                   userRef;
    // NOTE: EnumDevices is synchronous — ctx is alive for the entire call.
    static BOOL CALLBACK cb(LPCDIDEVICEINSTANCEW lpddi, LPVOID pv) {
        auto* c = static_cast<EnumDevCtxW*>(pv);
        if (Config::instance().isDeviceHidden(lpddi->tszProductName)) {
            LOG_INFO("EnumDevices: hiding [%ls]", lpddi->tszProductName);
            return DIENUM_CONTINUE;
        }
        return c->userCb(lpddi, c->userRef);
    }
};

struct EnumDevCtxA {
    LPDIENUMDEVICESCALLBACKA userCb;
    LPVOID                   userRef;
    // NOTE: EnumDevices is synchronous — ctx is alive for the entire call.
    static BOOL CALLBACK cb(LPCDIDEVICEINSTANCEA lpddi, LPVOID pv) {
        auto* c = static_cast<EnumDevCtxA*>(pv);
        std::wstring ws = ansiToWide(lpddi->tszProductName);
        if (Config::instance().isDeviceHidden(ws.c_str())) {
            LOG_INFO("EnumDevices: hiding [%ls]", ws.c_str());
            return DIENUM_CONTINUE;
        }
        return c->userCb(lpddi, c->userRef);
    }
};

// Callback trampolines for device-hide filtering in EnumDevicesBySemantics

struct EnumSemCtxW {
    LPDIENUMDEVICESBYSEMANTICSCBW userCb;
    LPVOID                        userRef;
    // NOTE: EnumDevicesBySemantics is synchronous — ctx is alive for the entire call.
    static BOOL CALLBACK cb(LPCDIDEVICEINSTANCEW lpddi,
                             IDirectInputDevice8W* pdid,
                             DWORD dwFlags, DWORD dwRemaining, LPVOID pv) {
        auto* c = static_cast<EnumSemCtxW*>(pv);
        if (Config::instance().isDeviceHidden(lpddi->tszProductName)) {
            LOG_INFO("EnumDevicesBySemantics: hiding [%ls]", lpddi->tszProductName);
            return DIENUM_CONTINUE;
        }
        return c->userCb(lpddi, pdid, dwFlags, dwRemaining, c->userRef);
    }
};

struct EnumSemCtxA {
    LPDIENUMDEVICESBYSEMANTICSCBA userCb;
    LPVOID                        userRef;
    // NOTE: EnumDevicesBySemantics is synchronous — ctx is alive for the entire call.
    static BOOL CALLBACK cb(LPCDIDEVICEINSTANCEA lpddi,
                             IDirectInputDevice8A* pdid,
                             DWORD dwFlags, DWORD dwRemaining, LPVOID pv) {
        auto* c = static_cast<EnumSemCtxA*>(pv);
        std::wstring ws = ansiToWide(lpddi->tszProductName);
        if (Config::instance().isDeviceHidden(ws.c_str())) {
            LOG_INFO("EnumDevicesBySemantics: hiding [%ls]", ws.c_str());
            return DIENUM_CONTINUE;
        }
        return c->userCb(lpddi, pdid, dwFlags, dwRemaining, c->userRef);
    }
};

// ============================================================================
// Construction / destruction
// ============================================================================
template<bool U>
WrapperDirectInput8<U>::WrapperDirectInput8(Base* real)
    : m_real(real)
{
    LOG_INFO("WrapperDirectInput8<%s> created", U ? "W" : "A");
}

template<bool U>
WrapperDirectInput8<U>::~WrapperDirectInput8() {
    LOG_DEBUG("WrapperDirectInput8<%s> destroyed", U ? "W" : "A");
    if (m_real) m_real->Release();
}

// ============================================================================
// IUnknown
// ============================================================================
template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::QueryInterface(REFIID riid, void** ppvObj) {
    if (!ppvObj) return E_POINTER;

    if (riid == IID_IUnknown) {
        *ppvObj = static_cast<Base*>(this);
        AddRef();
        return S_OK;
    }
    if constexpr (U) {
        if (riid == IID_IDirectInput8W) {
            *ppvObj = static_cast<IDirectInput8W*>(this);
            AddRef();
            return S_OK;
        }
    } else {
        if (riid == IID_IDirectInput8A) {
            *ppvObj = static_cast<IDirectInput8A*>(this);
            AddRef();
            return S_OK;
        }
    }

    *ppvObj = nullptr;
    return m_real->QueryInterface(riid, ppvObj);
}

template<bool U>
ULONG STDMETHODCALLTYPE WrapperDirectInput8<U>::AddRef() {
    return InterlockedIncrement(&m_refCount);
}

template<bool U>
ULONG STDMETHODCALLTYPE WrapperDirectInput8<U>::Release() {
    ULONG c = InterlockedDecrement(&m_refCount);
    if (c == 0) delete this;
    return c;
}

// ============================================================================
// CreateDevice — the main interception point
// ============================================================================

// Helper: query device product name (wide string) from a real device.
static std::wstring queryDeviceName(IDirectInputDevice8W* dev) {
    DIDEVICEINSTANCEW di{};
    di.dwSize = sizeof(di);
    if (SUCCEEDED(dev->GetDeviceInfo(&di)))
        return di.tszProductName;
    return L"<unknown>";
}

static std::wstring queryDeviceName(IDirectInputDevice8A* dev) {
    DIDEVICEINSTANCEA di{};
    di.dwSize = sizeof(di);
    if (SUCCEEDED(dev->GetDeviceInfo(&di))) {
        // Convert narrow product name to wide for consistent policy lookup
        int len = MultiByteToWideChar(CP_ACP, 0, di.tszProductName, -1, nullptr, 0);
        std::wstring ws(len, L'\0');
        MultiByteToWideChar(CP_ACP, 0, di.tszProductName, -1, ws.data(), len);
        if (!ws.empty() && ws.back() == L'\0') ws.pop_back();
        return ws;
    }
    return L"<unknown>";
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::CreateDevice(
    REFGUID rguid, DevIfaceT** lplpDevice, LPUNKNOWN punkOuter)
{
    if (!lplpDevice) return E_POINTER;

    // Create the real device
    DevIfaceT* realDevice = nullptr;
    HRESULT hr = m_real->CreateDevice(rguid, &realDevice, punkOuter);
    if (FAILED(hr) || !realDevice) {
        *lplpDevice = nullptr;
        return hr;
    }

    // If wrapper is globally disabled, return unwrapped device
    if (!Config::instance().enabled) {
        *lplpDevice = realDevice;
        return hr;
    }

    // Query name and check if device should be hidden
    std::wstring name = queryDeviceName(realDevice);

    if (Config::instance().isDeviceHidden(name.c_str())) {
        LOG_INFO("CreateDevice: hiding device [%ls]", name.c_str());
        realDevice->Release();
        *lplpDevice = nullptr;
        return DIERR_DEVICENOTREG;
    }

    // Resolve FFB policy

    bool ffbEnabled = true;
    int  ffbScale   = 100;
    Config::instance().getDevicePolicy(name.c_str(), ffbEnabled, ffbScale);

    LOG_INFO("CreateDevice: [%ls]  FFB=%s  scale=%d%%",
             name.c_str(),
             ffbEnabled ? "allowed" : "BLOCKED",
             ffbScale);

    FFBPolicy policy;
    policy.enabled = ffbEnabled;
    policy.scale   = ffbScale;

    auto filter = std::make_shared<FFBFilter>(policy, name);

    // Wrap the device
    *lplpDevice = new WrapperDevice8<U>(realDevice, filter);
    return hr;
}

// ============================================================================
// Pass-through methods
// ============================================================================
template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::EnumDevices(
    DWORD dwDevType, EnumDevCbT lpCallback, LPVOID pvRef, DWORD dwFlags)
{
    if (!lpCallback)
        return m_real->EnumDevices(dwDevType, lpCallback, pvRef, dwFlags);

    if constexpr (U) {
        EnumDevCtxW ctx{ lpCallback, pvRef };
        return m_real->EnumDevices(dwDevType, EnumDevCtxW::cb, &ctx, dwFlags);
    } else {
        EnumDevCtxA ctx{ lpCallback, pvRef };
        return m_real->EnumDevices(dwDevType, EnumDevCtxA::cb, &ctx, dwFlags);
    }
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::GetDeviceStatus(REFGUID rguidInstance) {
    return m_real->GetDeviceStatus(rguidInstance);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::RunControlPanel(
    HWND hwndOwner, DWORD dwFlags)
{
    return m_real->RunControlPanel(hwndOwner, dwFlags);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::Initialize(
    HINSTANCE hinst, DWORD dwVersion)
{
    return m_real->Initialize(hinst, dwVersion);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::FindDevice(
    REFGUID rguidClass, const Char* ptszName, LPGUID pguidInstance)
{
    return m_real->FindDevice(rguidClass, ptszName, pguidInstance);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::EnumDevicesBySemantics(
    const Char* ptszUserName, ActFmtT* lpdiActionFormat,
    EnumSemCbT lpCallback, LPVOID pvRef, DWORD dwFlags)
{
    if (!lpCallback)
        return m_real->EnumDevicesBySemantics(
            ptszUserName, lpdiActionFormat, lpCallback, pvRef, dwFlags);

    if constexpr (U) {
        EnumSemCtxW ctx{ lpCallback, pvRef };
        return m_real->EnumDevicesBySemantics(
            ptszUserName, lpdiActionFormat, EnumSemCtxW::cb, &ctx, dwFlags);
    } else {
        EnumSemCtxA ctx{ lpCallback, pvRef };
        return m_real->EnumDevicesBySemantics(
            ptszUserName, lpdiActionFormat, EnumSemCtxA::cb, &ctx, dwFlags);
    }
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::ConfigureDevices(
    LPDICONFIGUREDEVICESCALLBACK lpdiCallback, CfgDevParamsT* lpdiCDParams,
    DWORD dwFlags, LPVOID pvRefData)
{
    return m_real->ConfigureDevices(lpdiCallback, lpdiCDParams, dwFlags, pvRefData);
}

// ============================================================================
// Explicit instantiations
// ============================================================================
template class WrapperDirectInput8<false>;  // A
template class WrapperDirectInput8<true>;   // W
