// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Valmantas Paliksa
#include "wrapper_dinput8.h"
#include "wrapper_device8.h"
#include "telemetry.h"

#include <new>
#include <cstring>
#include <string>

namespace {

std::string product_name(IDirectInputDevice8W* device) {
    DIDEVICEINSTANCEW info{};
    info.dwSize = sizeof(info);
    if (FAILED(device->GetDeviceInfo(&info))) return {};
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                         info.tszProductName, -1, nullptr, 0,
                                         nullptr, nullptr);
    if (size <= 1) return {};
    // `size` includes the terminating NUL when the source length is -1.
    // Keep room for it during the Win32 call, then expose only the text.
    std::string result(static_cast<std::size_t>(size), '\0');
    const int written = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, info.tszProductName, -1, result.data(),
        size, nullptr, nullptr);
    if (written != size) return {};
    result.resize(static_cast<std::size_t>(size - 1));
    return result;
}

std::string product_name(IDirectInputDevice8A* device) {
    DIDEVICEINSTANCEA info{};
    info.dwSize = sizeof(info);
    if (FAILED(device->GetDeviceInfo(&info))) return {};
    const int wide_size = MultiByteToWideChar(CP_ACP, 0, info.tszProductName,
                                               -1, nullptr, 0);
    if (wide_size <= 1) return {};
    std::wstring wide(static_cast<std::size_t>(wide_size), L'\0');
    const int wide_written = MultiByteToWideChar(
        CP_ACP, 0, info.tszProductName, -1, wide.data(), wide_size);
    if (wide_written != wide_size) return {};
    wide.resize(static_cast<std::size_t>(wide_size - 1));
    const int utf8_size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                              wide.c_str(), -1, nullptr, 0,
                                              nullptr, nullptr);
    if (utf8_size <= 1) return {};
    std::string result(static_cast<std::size_t>(utf8_size), '\0');
    const int utf8_written = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, wide.c_str(), -1, result.data(),
        utf8_size, nullptr, nullptr);
    if (utf8_written != utf8_size) return {};
    result.resize(static_cast<std::size_t>(utf8_size - 1));
    return result;
}

void emit_device(std::uint32_t id, REFGUID guid, HRESULT hr,
                 const std::string& name) noexcept {
    ffb::Event event{};
    event.type = ffb::MessageType::DeviceCreated;
    event.process_id = GetCurrentProcessId();
    event.device_id = id;
    event.effect_guid = guid;
    event.hresult = hr;
    strncpy_s(event.text, sizeof(event.text), name.c_str(), _TRUNCATE);
    ffb::Telemetry::instance().emit(event);
}

}  // namespace

template<bool U>
WrapperDirectInput8<U>::WrapperDirectInput8(Base* real) : m_real(real) {}

template<bool U>
WrapperDirectInput8<U>::~WrapperDirectInput8() {
    if (m_real) m_real->Release();
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::QueryInterface(REFIID riid,
                                                                   void** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (riid == IID_IUnknown ||
        (U ? riid == IID_IDirectInput8W : riid == IID_IDirectInput8A)) {
        *out = static_cast<Base*>(this);
        AddRef();
        return S_OK;
    }
    return m_real ? m_real->QueryInterface(riid, out) : E_NOINTERFACE;
}

template<bool U>
ULONG STDMETHODCALLTYPE WrapperDirectInput8<U>::AddRef() {
    return static_cast<ULONG>(InterlockedIncrement(&m_ref_count));
}

template<bool U>
ULONG STDMETHODCALLTYPE WrapperDirectInput8<U>::Release() {
    const ULONG count = static_cast<ULONG>(InterlockedDecrement(&m_ref_count));
    if (count == 0) delete this;
    return count;
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::CreateDevice(
    REFGUID rguid, DevIfaceT** out_device, LPUNKNOWN outer) {
    if (!out_device) return E_POINTER;
    *out_device = nullptr;
    if (!m_real) return DIERR_NOTINITIALIZED;
    DevIfaceT* real = nullptr;
    const HRESULT hr = m_real->CreateDevice(rguid, &real, outer);
    if (FAILED(hr) || !real) {
        emit_device(0, rguid, hr, {});
        return hr;
    }
    if (outer != nullptr) {
        emit_device(0, rguid, hr, {});
        *out_device = real;
        return hr;
    }

    const std::uint32_t device_id = ffb::Telemetry::instance().next_device_id();
    try {
        if (U) {
            emit_device(device_id, rguid, hr, product_name(
                reinterpret_cast<IDirectInputDevice8W*>(real)));
        } else {
            emit_device(device_id, rguid, hr, product_name(
                reinterpret_cast<IDirectInputDevice8A*>(real)));
        }
    } catch (...) {
        // Metadata is best-effort; allocation/encoding failures never alter
        // the DirectInput result or prevent the game from receiving a device.
        emit_device(device_id, rguid, hr, {});
    }
    auto* wrapped = new (std::nothrow) WrapperDevice8<U>(real, device_id);
    if (!wrapped) {
        *out_device = real;
        return hr;
    }
    *out_device = wrapped;
    return hr;
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::EnumDevices(
    DWORD type, EnumDevCbT callback, LPVOID ref, DWORD flags) {
    return m_real->EnumDevices(type, callback, ref, flags);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::GetDeviceStatus(REFGUID guid) {
    return m_real->GetDeviceStatus(guid);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::RunControlPanel(HWND owner, DWORD flags) {
    return m_real->RunControlPanel(owner, flags);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::Initialize(HINSTANCE instance, DWORD version) {
    return m_real->Initialize(instance, version);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::FindDevice(REFGUID guid, const Char* name,
                                                               LPGUID out) {
    return m_real->FindDevice(guid, name, out);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::EnumDevicesBySemantics(
    const Char* user, ActFmtT* format, EnumSemCbT callback, LPVOID ref, DWORD flags) {
    return m_real->EnumDevicesBySemantics(user, format, callback, ref, flags);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::ConfigureDevices(
    LPDICONFIGUREDEVICESCALLBACK callback, CfgDevParamsT* params, DWORD flags, LPVOID ref) {
    return m_real->ConfigureDevices(callback, params, flags, ref);
}

template class WrapperDirectInput8<false>;
template class WrapperDirectInput8<true>;
