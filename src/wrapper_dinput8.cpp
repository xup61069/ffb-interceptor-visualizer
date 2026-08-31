// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Valmantas Paliksa
#include "wrapper_dinput8.h"
#include "wrapper_device8.h"
#include "telemetry.h"

#include <new>
#include <cstring>
#include <string>

namespace {

template<bool U>
using DeviceInstanceT =
    std::conditional_t<U, DIDEVICEINSTANCEW, DIDEVICEINSTANCEA>;

template<bool U>
using DeviceInterfaceT =
    std::conditional_t<U, IDirectInputDevice8W, IDirectInputDevice8A>;

template<bool U>
using SemanticsCallbackT = std::conditional_t<
    U, LPDIENUMDEVICESBYSEMANTICSCBW, LPDIENUMDEVICESBYSEMANTICSCBA>;

template<bool U>
struct SemanticsCallbackContext {
    SemanticsCallbackT<U> callback = nullptr;
    LPVOID ref = nullptr;
};

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
    ffb::copy_utf8_truncated(event.text, sizeof(event.text), name);
    ffb::Telemetry::instance().emit(event);
}

template<bool U>
BOOL CALLBACK semantics_callback(const DeviceInstanceT<U>* instance,
                                 DeviceInterfaceT<U>* real, DWORD flags,
                                 DWORD remaining, LPVOID opaque) {
    auto* context = static_cast<SemanticsCallbackContext<U>*>(opaque);
    if (!context || !context->callback) return DIENUM_STOP;
    if (!real) {
        return context->callback(instance, nullptr, flags, remaining,
                                 context->ref);
    }

    // EnumDevicesBySemantics lends the interface to the callback. Take one
    // real reference for the wrapper's lifetime; the matching wrapper Release
    // below drops it unless the application AddRefs the callback argument.
    real->AddRef();
    const std::uint32_t device_id =
        ffb::Telemetry::instance().next_device_id();
    const GUID guid = instance ? instance->guidInstance : GUID_NULL;
    std::string name;
    try {
        name = product_name(real);
    } catch (...) {
        name.clear();
    }

    bool created = false;
    auto* wrapped = WrapperDevice8<U>::publish_or_add_ref(
        real, device_id, &created);
    if (!wrapped) {
        // Preserve fail-open behaviour if a control block or its A/W alias
        // cannot be allocated. discard_unpublished returns ownership of our
        // added reference, which is balanced before forwarding the raw value.
        real->Release();
        return context->callback(instance, real, flags, remaining,
                                 context->ref);
    }
    if (created) emit_device(device_id, guid, DI_OK, name);

    const BOOL result = context->callback(instance, wrapped, flags, remaining,
                                          context->ref);
    wrapped->Release();
    return result;
}

}  // namespace

struct WrapperDirectInput8State {
    volatile LONG ref_count = 1;
    IDirectInput8A* real_a = nullptr;
    IDirectInput8W* real_w = nullptr;
    WrapperDirectInput8A* wrapper_a = nullptr;
    WrapperDirectInput8W* wrapper_w = nullptr;

    bool valid() const noexcept {
        // A successful QI for the alternate A/W interface creates an
        // additional real reference that must have a matching wrapper.  If
        // that allocation fails, publishing this object would violate the
        // COM contract and break fail-open forwarding.
        return (!real_a || wrapper_a) && (!real_w || wrapper_w);
    }

    ~WrapperDirectInput8State() {
        delete wrapper_a;
        delete wrapper_w;
        if (real_a) real_a->Release();
        if (real_w) real_w->Release();
    }

    void* canonical_unknown() const noexcept {
        if (wrapper_a) return static_cast<IDirectInput8A*>(wrapper_a);
        return static_cast<IDirectInput8W*>(wrapper_w);
    }

    ULONG add_ref() noexcept {
        return static_cast<ULONG>(InterlockedIncrement(&ref_count));
    }

    ULONG release() noexcept {
        const ULONG count = static_cast<ULONG>(InterlockedDecrement(&ref_count));
        if (count == 0) delete this;
        return count;
    }
};

template<bool U>
WrapperDirectInput8<U>::WrapperDirectInput8(Base* real) : m_real(real) {
    m_state = new (std::nothrow) WrapperDirectInput8State();
    if (!m_state) return;

    if constexpr (U) {
        m_state->real_w = static_cast<IDirectInput8W*>(real);
        m_state->wrapper_w = static_cast<WrapperDirectInput8W*>(this);
        real->QueryInterface(IID_IDirectInput8A,
                             reinterpret_cast<void**>(&m_state->real_a));
        if (m_state->real_a) {
            m_state->wrapper_a =
                new (std::nothrow) WrapperDirectInput8A(m_state, m_state->real_a);
        }
    } else {
        m_state->real_a = static_cast<IDirectInput8A*>(real);
        m_state->wrapper_a = static_cast<WrapperDirectInput8A*>(this);
        real->QueryInterface(IID_IDirectInput8W,
                             reinterpret_cast<void**>(&m_state->real_w));
        if (m_state->real_w) {
            m_state->wrapper_w =
                new (std::nothrow) WrapperDirectInput8W(m_state, m_state->real_w);
        }
    }
}

template<bool U>
WrapperDirectInput8<U>::WrapperDirectInput8(WrapperDirectInput8State* state,
                                             Base* real)
    : m_real(real), m_state(state) {}

template<bool U>
WrapperDirectInput8<U>::~WrapperDirectInput8() = default;

template<bool U>
bool WrapperDirectInput8<U>::valid() const noexcept {
    return m_state != nullptr && m_state->valid();
}

template<bool U>
void WrapperDirectInput8<U>::discard_unpublished() noexcept {
    if (!m_state) {
        delete this;
        return;
    }
    // The original interface reference belongs to the caller's output slot.
    // Detach only that field; alias references acquired by QueryInterface
    // remain owned by the state and are released by its destructor.
    if constexpr (U) {
        m_state->real_w = nullptr;
    } else {
        m_state->real_a = nullptr;
    }
    m_real = nullptr;
    Release();
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::QueryInterface(REFIID riid,
                                                                   void** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (!m_state) return E_NOINTERFACE;
    if (riid == IID_IUnknown) {
        *out = m_state->canonical_unknown();
        m_state->add_ref();
        return S_OK;
    }
    if (riid == IID_IDirectInput8A && m_state->wrapper_a) {
        *out = static_cast<IDirectInput8A*>(m_state->wrapper_a);
        m_state->add_ref();
        return S_OK;
    }
    if (riid == IID_IDirectInput8W && m_state->wrapper_w) {
        *out = static_cast<IDirectInput8W*>(m_state->wrapper_w);
        m_state->add_ref();
        return S_OK;
    }
    return m_real ? m_real->QueryInterface(riid, out) : E_NOINTERFACE;
}

template<bool U>
ULONG STDMETHODCALLTYPE WrapperDirectInput8<U>::AddRef() {
    return m_state ? m_state->add_ref() : 0;
}

template<bool U>
ULONG STDMETHODCALLTYPE WrapperDirectInput8<U>::Release() {
    return m_state ? m_state->release() : 0;
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
    std::string name;
    try {
        if (U) {
            name = product_name(reinterpret_cast<IDirectInputDevice8W*>(real));
        } else {
            name = product_name(reinterpret_cast<IDirectInputDevice8A*>(real));
        }
    } catch (...) {
        // Metadata is best-effort; allocation/encoding failures never alter
        // the DirectInput result or prevent the game from receiving a device.
        name.clear();
    }
    bool created = false;
    auto* wrapped = WrapperDevice8<U>::publish_or_add_ref(
        real, device_id, &created);
    // WrapperDevice8 allocates a shared A/W control block.  If that
    // allocation fails, returning the partially constructed wrapper would
    // turn an otherwise valid DirectInput device into a broken COM object.
    // Preserve fail-open semantics by discarding it and returning the exact
    // real interface the system DLL supplied.
    if (!wrapped || !wrapped->valid()) {
        *out_device = real;
        return hr;
    }
    if (created) emit_device(device_id, rguid, hr, name);
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
    if (!callback) {
        return m_real->EnumDevicesBySemantics(user, format, callback, ref,
                                              flags);
    }
    SemanticsCallbackContext<U> context{callback, ref};
    return m_real->EnumDevicesBySemantics(
        user, format, &semantics_callback<U>, &context, flags);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDirectInput8<U>::ConfigureDevices(
    LPDICONFIGUREDEVICESCALLBACK callback, CfgDevParamsT* params, DWORD flags, LPVOID ref) {
    return m_real->ConfigureDevices(callback, params, flags, ref);
}

template class WrapperDirectInput8<false>;
template class WrapperDirectInput8<true>;
