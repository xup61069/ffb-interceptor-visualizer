// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Valmantas Paliksa
#include "wrapper_device8.h"
#include "wrapper_effect.h"
#include "telemetry.h"

#include <new>

namespace {

void emit_effect(std::uint32_t device_id, std::uint32_t effect_id, REFGUID guid,
                 LPCDIEFFECT parameters, HRESULT hr) noexcept {
    ffb::Event event{};
    event.type = ffb::MessageType::EffectCreated;
    event.effect_kind = ffb::effect_kind_from_guid(guid);
    event.process_id = GetCurrentProcessId();
    event.device_id = device_id;
    event.effect_id = effect_id;
    event.effect_guid = guid;
    event.hresult = hr;
    ffb::fill_effect_parameters(event, parameters);
    ffb::Telemetry::instance().emit(event);
}

void emit_property(std::uint32_t device_id, REFGUID property,
                   LPCDIPROPHEADER header, HRESULT hr) noexcept {
    if (!IsEqualGUID(property, DIPROP_FFGAIN) && !IsEqualGUID(property, DIPROP_AUTOCENTER)) return;
    ffb::Event event{};
    event.type = ffb::MessageType::DevicePropertyChanged;
    event.process_id = GetCurrentProcessId();
    event.device_id = device_id;
    event.property_id = IsEqualGUID(property, DIPROP_FFGAIN) ? 1u : 2u;
    event.hresult = hr;
    __try {
        if (header && header->dwSize >= sizeof(DIPROPDWORD)) {
            event.gain = reinterpret_cast<const DIPROPDWORD*>(header)->dwData;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        event.gain = 0;
    }
    ffb::Telemetry::instance().emit(event);
}

}  // namespace

template<bool U>
WrapperDevice8<U>::WrapperDevice8(Base* real, std::uint32_t device_id)
    : m_real(real), m_device_id(device_id) {}

template<bool U>
WrapperDevice8<U>::~WrapperDevice8() {
    if (m_real) m_real->Release();
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::QueryInterface(REFIID riid, void** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (riid == IID_IUnknown ||
        (U ? riid == IID_IDirectInputDevice8W : riid == IID_IDirectInputDevice8A)) {
        *out = static_cast<Base*>(this);
        AddRef();
        return S_OK;
    }
    return m_real ? m_real->QueryInterface(riid, out) : E_NOINTERFACE;
}

template<bool U>
ULONG STDMETHODCALLTYPE WrapperDevice8<U>::AddRef() {
    return static_cast<ULONG>(InterlockedIncrement(&m_ref_count));
}

template<bool U>
ULONG STDMETHODCALLTYPE WrapperDevice8<U>::Release() {
    const ULONG count = static_cast<ULONG>(InterlockedDecrement(&m_ref_count));
    if (count == 0) delete this;
    return count;
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetCapabilities(LPDIDEVCAPS value) {
    return m_real->GetCapabilities(value);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::EnumObjects(EnumObjCbT callback, LPVOID ref, DWORD flags) {
    return m_real->EnumObjects(callback, ref, flags);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetProperty(REFGUID guid, LPDIPROPHEADER header) {
    return m_real->GetProperty(guid, header);
}

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SetProperty(REFGUID guid, LPCDIPROPHEADER header) {
    const HRESULT hr = m_real->SetProperty(guid, header);
    emit_property(m_device_id, guid, header, hr);
    return hr;
}

template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::Acquire() { return m_real->Acquire(); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::Unacquire() { return m_real->Unacquire(); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetDeviceState(DWORD size, LPVOID data) { return m_real->GetDeviceState(size, data); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetDeviceData(DWORD size, LPDIDEVICEOBJECTDATA data, LPDWORD count, DWORD flags) { return m_real->GetDeviceData(size, data, count, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SetDataFormat(LPCDIDATAFORMAT format) { return m_real->SetDataFormat(format); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SetEventNotification(HANDLE event) { return m_real->SetEventNotification(event); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SetCooperativeLevel(HWND window, DWORD flags) { return m_real->SetCooperativeLevel(window, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetObjectInfo(DevObjInstT* info, DWORD object, DWORD how) { return m_real->GetObjectInfo(info, object, how); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetDeviceInfo(DevInstT* info) { return m_real->GetDeviceInfo(info); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::RunControlPanel(HWND owner, DWORD flags) { return m_real->RunControlPanel(owner, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::Initialize(HINSTANCE instance, DWORD version, REFGUID guid) { return m_real->Initialize(instance, version, guid); }

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::CreateEffect(REFGUID guid, LPCDIEFFECT parameters,
                                                            LPDIRECTINPUTEFFECT* out, LPUNKNOWN outer) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (!m_real) return DIERR_NOTINITIALIZED;
    IDirectInputEffect* real = nullptr;
    const HRESULT hr = m_real->CreateEffect(guid, parameters, &real, outer);
    if (FAILED(hr) || !real || outer != nullptr) {
        emit_effect(m_device_id, 0, guid, parameters, hr);
        *out = real;
        return hr;
    }
    const std::uint32_t effect_id = ffb::Telemetry::instance().next_effect_id();
    auto* wrapped = new (std::nothrow) WrapperEffect(real, m_device_id, effect_id, guid);
    if (!wrapped) {
        emit_effect(m_device_id, effect_id, guid, parameters, hr);
        *out = real;
        return hr;
    }
    emit_effect(m_device_id, effect_id, guid, parameters, hr);
    *out = wrapped;
    return hr;
}

template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::EnumEffects(EnumFxCbT callback, LPVOID ref, DWORD type) { return m_real->EnumEffects(callback, ref, type); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetEffectInfo(EffInfoT* info, REFGUID guid) { return m_real->GetEffectInfo(info, guid); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetForceFeedbackState(LPDWORD value) { return m_real->GetForceFeedbackState(value); }

template<bool U>
HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SendForceFeedbackCommand(DWORD flags) {
    const HRESULT hr = m_real->SendForceFeedbackCommand(flags);
    ffb::Event event{};
    event.type = ffb::MessageType::DeviceCommand;
    event.process_id = GetCurrentProcessId();
    event.device_id = m_device_id;
    event.di_flags = flags;
    event.hresult = hr;
    ffb::Telemetry::instance().emit(event);
    return hr;
}

template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::EnumCreatedEffectObjects(LPDIENUMCREATEDEFFECTOBJECTSCALLBACK callback, LPVOID ref, DWORD flags) { return m_real->EnumCreatedEffectObjects(callback, ref, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::Escape(LPDIEFFESCAPE escape) { return m_real->Escape(escape); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::Poll() { return m_real->Poll(); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SendDeviceData(DWORD size, LPCDIDEVICEOBJECTDATA data, LPDWORD count, DWORD flags) { return m_real->SendDeviceData(size, data, count, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::BuildActionMap(ActFmtT* format, const Char* user, DWORD flags) { return m_real->BuildActionMap(format, user, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::SetActionMap(ActFmtT* format, const Char* user, DWORD flags) { return m_real->SetActionMap(format, user, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::GetImageInfo(std::conditional_t<U, LPDIDEVICEIMAGEINFOHEADERW, LPDIDEVICEIMAGEINFOHEADERA> info) { return m_real->GetImageInfo(info); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::EnumEffectsInFile(const Char* file, LPDIENUMEFFECTSINFILECALLBACK callback, LPVOID ref, DWORD flags) { return m_real->EnumEffectsInFile(file, callback, ref, flags); }
template<bool U> HRESULT STDMETHODCALLTYPE WrapperDevice8<U>::WriteEffectToFile(const Char* file, DWORD entries, LPDIFILEEFFECT effects, DWORD flags) { return m_real->WriteEffectToFile(file, entries, effects, flags); }

template class WrapperDevice8<false>;
template class WrapperDevice8<true>;
